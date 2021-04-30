{-# LANGUAGE RecordWildCards #-}

module Smos.Server.Handler.GetBackup
  ( serveGetBackup,
    prepareBackupFilePath,
  )
where

import Codec.Archive.Zip as Zip
import Conduit
import Data.ByteString (ByteString)
import qualified Data.Conduit.Combinators as C
import Servant.Types.SourceT as Source
import Smos.Server.Handler.Import
import System.FilePath.Posix as Posix
import System.FilePath.Windows as Windows
import UnliftIO

serveGetBackup :: AuthCookie -> BackupUUID -> ServerHandler (SourceIO ByteString)
serveGetBackup AuthCookie {..} uuid = withUserId authCookieUsername $ \uid -> do
  mBackup <- runDB $ getBy $ UniqueBackupUUID uid uuid
  case mBackup of
    Nothing -> throwError err404
    Just (Entity bid _) -> do
      systemTempDir <- getTempDir
      tmpDir <- createTempDir systemTempDir "smos-server-temp-archive-dir"
      tempArchiveFileName <- resolveFile tmpDir "backup.zip"
      runDB $ do
        ackBackupFileSource <- selectSourceRes [BackupFileBackup ==. bid] []
        withAcquire ackBackupFileSource $ \backupFileSource -> do
          -- Create a zip archive
          Zip.createArchive (fromAbsFile tempArchiveFileName) $ do
            let insertBackupFile (Entity _ BackupFile {..}) = do
                  -- NOTE: Running 'Zip.mkEntrySelector' in 'Maybe' instead of 'IO'
                  -- (because it can be run in any 'MonadThrow') means that we could be
                  -- missing files in the resulting zip file.  However: We think that
                  -- that is better than not being able to download any backups.
                  let mSelector :: Maybe Zip.EntrySelector
                      mSelector = Zip.mkEntrySelector (prepareBackupFilePath backupFilePath)
                  let contents = decompressByteStringOrErrorMessage backupFileContents
                  forM_ mSelector $ Zip.addEntry Zip.Deflate contents
            runConduit $ backupFileSource .| C.mapM_ insertBackupFile
          -- Stream the zip archive
          pure $
            SourceT $ \step -> do
              let SourceT func = Source.readFile (fromAbsFile tempArchiveFileName)
              func step `finally` removeDirRecur tmpDir

prepareBackupFilePath :: Path Rel File -> FilePath
prepareBackupFilePath = Windows.makeValid . Posix.makeValid . fromRelFile
