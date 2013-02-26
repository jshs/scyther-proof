module Paths_scyther_proof (
    version,
    getBinDir, getLibDir, getDataDir, getLibexecDir,
    getDataFileName
  ) where

import qualified Control.Exception as Exception
import Data.Version (Version(..))
import System.Environment (getEnv)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
catchIO = Exception.catch


version :: Version
version = Version {versionBranch = [0,7,0,0], versionTags = []}
bindir, libdir, datadir, libexecdir :: FilePath

bindir     = "."
libdir     = "."
datadir    = "data"
libexecdir = "."

getBinDir, getLibDir, getDataDir, getLibexecDir :: IO FilePath
getBinDir = catchIO (getEnv "scyther_proof_bindir") (\_ -> return bindir)
getLibDir = catchIO (getEnv "scyther_proof_libdir") (\_ -> return libdir)
getDataDir = catchIO (getEnv "scyther_proof_datadir") (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "scyther_proof_libexecdir") (\_ -> return libexecdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "/" ++ name)
