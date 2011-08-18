module Main where

import GHC
import DynFlags
import MonadUtils
import Digraph (flattenSCC)
import HscTypes (handleFlagWarnings)
import HscTypes (dep_pkgs)
import PackageConfig
import Packages
import Module
import StaticFlags
import ErrUtils
import qualified Outputable as O
import qualified Pretty as GHCPretty
 
import GHC.Paths ( libdir )
 
import System.Environment
import System.Exit
import System.FilePath
import qualified Data.Set as Set
import Control.Exception as E
import System.IO
import System.Environment.Executable
import Text.PrettyPrint.HughesPJ
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Numeric (showHex)
import Data.Char (isPrint)

main = do
    args <- getArgs
    runGHCWithArgsForTargets args $ do
        setCustomLogger
        modules <- compileAndLoadModules
        targetFiles <- getTargetFiles
        let isTarget m = case ml_hs_file (ms_location m) of
                                Just f | f `elem` targetFiles -> True
                                _ -> False
        let targetModules = filter isTarget modules
        execName <- liftIO getExecutableName
        liftIO $ writeFile moduleInitFile $ moduleInitFileContents execName targetModules
        packageIds <- getUniquePackageIds modules
        maybeLinkFilePath <- liftIO getLinkFilePath
        case maybeLinkFilePath of
            Nothing -> printInstructions args modules packageIds
            Just f -> writeObjectFiles f modules packageIds

printInstructions :: [String] -> [ModSummary] -> [PackageId] -> Ghc ()
printInstructions args modules packageIds = do
    progName <- liftIO $ getExecutablePath
    stubHeaders <- getStubHeaders
    let progInvocation = progName ++ " " ++ unwords args
    rtsIncludeDir <- getIncludePaths
    let instructionList = 
            text "* Add Header Search Paths:"
            $$ nest 4 (text rtsIncludeDir)
            $$ text "* Add Other Linker Flags:"
            $$ nest 4 (text "-liconv")
            $$ nest 4 (text "-Wl,-no_compact_unwind,-no_pie")
            $$ text "* Add the following files to XCode:"
            $$ nest 4 (vcat $ map text $ [ moduleInitFile ] ++ stubHeaders)
            $$ text "* Add a \"Run Script\" build phase which occurs before the"
            $$ text "  \"Compile Sources\" phase and calls: "
            $$ nest 4 (text progInvocation) 
    liftIO $ print $ 
        text "You will need to make the following changes in XCode:"
        $$ nest 2 instructionList

writeObjectFiles linkFilePath modules packageIds = do
    objectFiles <- moduleObjectFiles modules
    packageLibFiles <- mapM getPackageLibraryFile packageIds
    let objFiles = objectFiles ++ packageLibFiles
    liftIO $ do
        hPutStrLn stderr $ "Adding object files:"
        mapM_ (hPutStrLn stderr) objFiles
        appendFile linkFilePath
            $ unlines $ objFiles
    
getLinkFilePath = E.catch (do
    arch <- getEnv "CURRENT_ARCH"
    variant <- getEnv "CURRENT_VARIANT"
    fmap Just $ getEnv $ "LINK_FILE_LIST_" ++ variant ++ "_" ++ arch)
            (\(e::IOException) -> return Nothing)

    
compileAndLoadModules = do
    liftIO $ hPutStrLn stderr "Compiling..."
    success <- load LoadAllTargets
    liftIO $ case success of
            Succeeded -> hPutStrLn stderr "Succeeded."
            Failed -> do
                        hPutStrLn stderr "Failed."
                        exitWith (ExitFailure 1)
    g <- depanal [] False
    let sccs = topSortModuleGraph False g Nothing
    return $ concatMap flattenSCC sccs
        
    

getUniquePackageIds modules = do
    all_deps <- flip mapM modules $ \theModule -> do
                        let m = ms_mod theModule
                        Just info <- getModuleInfo (ms_mod theModule)
                        let Just iface = modInfoIface info
                        return $ map fst $ dep_pkgs $ mi_deps iface
    return $ Set.toList $ Set.fromList 
           $ [rtsPackageId,stringToPackageId "ffi-1.0"] ++ concat all_deps
    
getPackageLibraryFile packageId = do
    dflags <- getSessionDynFlags
    let conf = getPackageDetails (pkgState dflags) packageId
    -- packagehsLibs takes -threaded, etc. into account
    -- for the rts package's libs
    let [libname] = packageHsLibs dflags conf
    let libdir:_ = libraryDirs conf
    return $ libdir </> "lib" ++ (libname :: String) <.> "a"


runGHCWithArgsForTargets args action = do
    let locatedArgs = map (mkGeneralLocated "on the command line")
                            args
    -- Static flags are necessary in particular to pick up "-threaded".
    (args', staticFlagWarnings) <- parseStaticFlags locatedArgs
    defaultErrorHandler defaultLogAction $ 
      runGhc (Just libdir) $ do
        dflags <- getSessionDynFlags
        defaultCleanupHandler dflags $ do
        dflags <- getSessionDynFlags
        (dflags2, fileish_args, dynamicFlagWarnings) <- parseDynamicFlags dflags args'
        handleSourceError (\e -> do
            GHC.printException e
            liftIO $ exitWith (ExitFailure 1)) $
          liftIO $ handleFlagWarnings dflags2 
                    $ staticFlagWarnings ++ dynamicFlagWarnings
        setSessionDynFlags dflags2
        let fileArgs = map unLoc fileish_args
        targets <- mapM (flip guessTarget Nothing) fileArgs
        setTargets targets
        action
    
moduleObjectFiles moduleSummaries = do
    targetFiles <- getTargetFiles
    return $ 
        map (ml_obj_file . ms_location) moduleSummaries
        -- stub files
        -- Apparently not needed in ghc-7.2.
        -- ++ map ((++ "_stub.o") . dropExtension) targetFiles

getTargetFiles = do
    targets <- getTargets
    return [f | TargetFile f _ <- map targetId targets]
    

getIncludePaths = do
    dflags <- getSessionDynFlags
    let [rtsIncludeDir] = includeDirs   
                            $ getPackageDetails (pkgState dflags)
                                                rtsPackageId
    return rtsIncludeDir

getStubHeaders = fmap (map ((++"_stub.h") . dropExtension))
                    getTargetFiles

---------
moduleInitFile = "_hs_module_init.c"

moduleInitFileContents execName moduleSummaries = unlines $
    [ "/* This file has been generated automatically by ghc-xcode."
    , "   You should not edit it directly. */"
    , "#include <HsFFI.h>"
    ]
    ++ ["#include \"" ++ f ++ "\"" | f <- map headerStub moduleSummaries ]
    ++ ["extern void " ++ s ++ "(void);" | s <- stginits] ++ 
    [ "static void library_init(void) __attribute__((constructor));"
    , "static void library_init(void)"
    , "{"
    , "static char *argv[] = { " ++ quotedCString execName ++ ", 0 }, **argv_ = argv;"
    , "static int argc = 1;"
    , ""
    , "hs_init(&argc, &argv_);"
    ]
    ++ ["hs_add_root(" ++ s ++ ");" | s <- stginits] ++
    [ "}"
    , ""
    , "static void library_exit(void) __attribute__((destructor));"
    , "static void library_exit(void)"
    , "{"
    , "hs_exit();"
    , "}"
    ]

  where
    stginits = map stginit moduleSummaries
    stginit m
        = "__stginit_" ++ (fixZEncoding $ moduleNameString $ moduleName $ ms_mod m)
    headerStub m
        = dropExtension (ml_obj_file $ ms_location m) ++ "_stub.h"

fixZEncoding = concatMap $ \c -> case c of
                '.' -> "zi"
                _ -> [c]


-- Return the value of ${EXECUTABLE_NAME}.
-- Return a default value if it's not set (most likely, because we're not running in XCode).
getExecutableName = E.catch (getEnv "EXECUTABLE_NAME")
                        (\(e::IOException) ->  return "PROGNAME")

-- Takes the input and turns it into a C expression representation of the string.
-- which is encoded in UTF-8 and escapes problem characters.
quotedCString :: String -> String
quotedCString = cRep . cvtToUTF8
  where
    cvtToUTF8 = B.unpack . encodeUtf8 . Text.pack
    cRep s = "\"" ++ concatMap cRepChar s ++ "\""
    cRepChar '"' = "\\\""
    cRepChar c
        | isPrint c && c < '\128' = [c]
        | otherwise = "\\x" ++ hexRep (fromEnum c)
    hexRep c
        | c < 16 = "0" ++ showHex c "" -- probably won't happen in practice
        | otherwise = showHex c ""

------------
-- Custom logger.

setCustomLogger :: Ghc ()
setCustomLogger = do
    -- Don't change the logger if we're running outside of XCode.
    execName <- liftIO $ E.try $ getEnv "EXECUTABLE_NAME"
    case execName of
        Left (e::IOException) -> return () -- not XCode
        Right _ -> do
                    dflags <- getSessionDynFlags
                    setSessionDynFlags dflags {log_action = myLogger}
                    return ()


-- XCode parses error messages of the forms:
-- Foo.hs:10: error: message
-- Foo.hs:10: warning: message
-- also possibly "note".
-- Unfortunately, GHC hard-codes "Warning: " in front of warnings,
-- so we can't handle them correctly yet.
myLogger :: LogAction
myLogger SevError span style msg = do
    GHCPretty.printDoc GHCPretty.OneLineMode stderr
            $ O.runSDoc fullMsg $ O.initSDocContext style
    hFlush stderr
  where fullMsg = mkXCodeLocMessage (srcSpanStart span) msg

mkXCodeLocMessage :: SrcLoc -> Message -> Message
mkXCodeLocMessage loc msg
    -- = O.hang (xcodeLoc loc) 4 msg
    = xcodeLoc loc O.<+> msg

xcodeLoc :: SrcLoc -> Message
xcodeLoc (UnhelpfulLoc s) = O.ftext s
xcodeLoc (RealSrcLoc loc)
        = O.ftext (srcLocFile loc) O.<> O.colon
            O.<> O.ppr (srcLocLine loc) O.<> O.colon
            O.<+> O.text "error:"
