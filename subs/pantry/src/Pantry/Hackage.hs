{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Pantry.Hackage
  ( updateHackageIndex
  , hackageIndexTarballL
  , getHackageTarball
  ) where

import RIO
import Data.Aeson
import Conduit
import Crypto.Hash.Conduit (sinkHash)
import Data.Conduit.Tar
import qualified RIO.Text as T
import qualified RIO.Map as Map
import Data.Text.Unsafe (unsafeTail)
import qualified RIO.ByteString as B
import qualified RIO.ByteString.Lazy as BL
import Pantry.Archive
import Pantry.Types hiding (FileType (..))
import Pantry.Storage
import Pantry.StaticSHA256
import Network.URI (parseURI)
import Network.HTTP.Client.TLS (getGlobalManager)
import Data.Time (getCurrentTime)
import RIO.FilePath ((</>))
import qualified Distribution.Text
import Distribution.Types.PackageName (unPackageName)
import System.IO (SeekMode (..))

import qualified Hackage.Security.Client as HS
import qualified Hackage.Security.Client.Repository.Cache as HS
import qualified Hackage.Security.Client.Repository.Remote as HS
import qualified Hackage.Security.Client.Repository.HttpLib.HttpClient as HS
import qualified Hackage.Security.Util.Path as HS
import qualified Hackage.Security.Util.Pretty as HS

hackageDirL :: HasPantryConfig env => SimpleGetter env FilePath
hackageDirL = pantryConfigL.to ((</> "hackage") . pcRootDir)

hackageIndexTarballL :: HasPantryConfig env => SimpleGetter env FilePath
hackageIndexTarballL = hackageDirL.to (</> "00-index.tar")

-- | Download the most recent 01-index.tar file from Hackage and
-- update the database tables.
--
-- Returns @True@ if an update occurred, @False@ if we've already
-- updated once.
updateHackageIndex
  :: (HasPantryConfig env, HasLogFunc env)
  => Maybe Utf8Builder -- ^ reason for updating, if any
  -> RIO env Bool
updateHackageIndex mreason = gateUpdate $ do
    for_ mreason logInfo
    pc <- view pantryConfigL
    let HackageSecurityConfig keyIds threshold url = pcHackageSecurity pc
    root <- view hackageDirL
    tarball <- view hackageIndexTarballL
    baseURI <-
        case parseURI $ T.unpack url of
            Nothing -> throwString $ "Invalid Hackage Security base URL: " ++ T.unpack url
            Just x -> return x
    manager <- liftIO getGlobalManager
    run <- askRunInIO
    let logTUF = run . logInfo . fromString . HS.pretty
        withRepo = HS.withRepository
            (HS.makeHttpLib manager)
            [baseURI]
            HS.defaultRepoOpts
            HS.Cache
                { HS.cacheRoot = HS.fromAbsoluteFilePath root
                , HS.cacheLayout = HS.cabalCacheLayout
                }
            HS.hackageRepoLayout
            HS.hackageIndexLayout
            logTUF
    didUpdate <- liftIO $ withRepo $ \repo -> HS.uncheckClientErrors $ do
        needBootstrap <- HS.requiresBootstrap repo
        when needBootstrap $ do
            HS.bootstrap
                repo
                (map (HS.KeyId . T.unpack) keyIds)
                (HS.KeyThreshold $ fromIntegral threshold)
        now <- getCurrentTime
        HS.checkForUpdates repo (Just now)

    case didUpdate of
        HS.NoUpdates -> logInfo "No package index update available"
        HS.HasUpdates -> logInfo "Updated package index downloaded"

    withStorage $ do
      -- Alright, here's the story. In theory, we only ever append to
      -- a tarball. Therefore, we can store the last place we
      -- populated our cache from, and fast forward to that point. But
      -- there are two issues with that:
      --
      -- 1. Hackage may rebase, in which case we need to recalculate
      -- everything from the beginning. Unfortunately,
      -- hackage-security doesn't let us know when that happens.
      --
      -- 2. Some paranoia about files on the filesystem getting
      -- modified out from under us.
      --
      -- Therefore, we store both the last read-to index, _and_ the
      -- SHA256 of all of the contents until that point. When updating
      -- the cache, we calculate the new SHA256 of the whole file, and
      -- the SHA256 of the previous read-to point. If the old hashes
      -- match, we can do an efficient fast forward. Otherwise, we
      -- clear the old cache and repopulate.
      minfo <- loadLatestCacheUpdate
      (offset, newHash, newSize) <- lift $ withBinaryFile tarball ReadMode $ \h -> do
        logInfo "Calculating hashes to check for hackage-security rebases or filesystem changes"

        -- The size of the new index tarball, ignoring the required
        -- (by the tar spec) 1024 null bytes at the end, which will be
        -- mutated in the future by other updates.
        newSize <- (fromIntegral . max 0 . subtract 1024) <$> hFileSize h
        let sinkSHA256 len = mkStaticSHA256FromDigest <$> (takeCE (fromIntegral len) .| sinkHash)

        case minfo of
          Nothing -> do
            logInfo "No old cache found, populating cache from scratch"
            newHash <- runConduit $ sourceHandle h .| sinkSHA256 newSize
            pure (0, newHash, newSize)
          Just (oldSize, oldHash) -> do
            -- oldSize and oldHash come from the database, and tell
            -- us what we cached already. Compare against
            -- oldHashCheck, which assuming the tarball has not been
            -- rebased will be the same as oldHash. At the same
            -- time, calculate newHash, which is the hash of the new
            -- content as well.
            (oldHashCheck, newHash) <- runConduit $ sourceHandle h .| getZipSink ((,)
              <$> ZipSink (sinkSHA256 oldSize)
              <*> ZipSink (sinkSHA256 newSize)
                                                                             )
            offset <-
              if oldHash == oldHashCheck
                then oldSize <$ logInfo "Updating preexisting cache, should be quick"
                else 0 <$ do
                  logInfo "Package index change detected, that's pretty unusual"
                  logInfo $ "Old size: " <> display oldSize
                  logInfo $ "Old hash (orig) : " <> display oldHash
                  logInfo $ "New hash (check): " <> display oldHashCheck
                  logInfo "Forcing a recache"
            pure (offset, newHash, newSize)

      lift $ logInfo $ "Populating cache from file size " <> display newSize <> ", hash " <> display newHash
      when (offset == 0) clearHackageRevisions
      populateCache tarball (fromIntegral offset) `onException`
        lift (logStickyDone "Failed populating package index cache")
      storeCacheUpdate newSize newHash
    logStickyDone "Package index cache populated"
  where
    gateUpdate inner = do
      pc <- view pantryConfigL
      join $ modifyMVar (pcUpdateRef pc) $ \toUpdate -> pure $
        if toUpdate
          then (False, True <$ inner)
          else (False, pure False)

-- | Populate the SQLite tables with Hackage index information.
populateCache
  :: (HasPantryConfig env, HasLogFunc env)
  => FilePath -- ^ tarball
  -> Integer -- ^ where to start processing from
  -> ReaderT SqlBackend (RIO env) ()
populateCache fp offset = withBinaryFile fp ReadMode $ \h -> do
  lift $ logInfo "Populating package index cache ..."
  counter <- newIORef (0 :: Int)
  hSeek h AbsoluteSeek offset
  runConduit $ sourceHandle h .| untar (perFile counter)
  where

    perFile counter fi
      | FTNormal <- fileType fi
      , Right path <- decodeUtf8' $ filePath fi
      , Just (name, version, filename) <- parseNameVersionSuffix path =
          if
            | filename == "package.json" ->
                sinkLazy >>= lift . addJSON name version
            | filename == T.pack (unPackageName name) <> ".cabal" -> do
                (BL.toStrict <$> sinkLazy) >>= lift . addCabal name version

                count <- readIORef counter
                let count' = count + 1
                writeIORef counter count'
                when (count' `mod` 400 == 0) $
                  lift $ lift $
                  logSticky $ "Processed " <> display count' <> " cabal files"
            | otherwise -> pure ()
      | otherwise = pure ()

    addJSON name version lbs =
      case eitherDecode' lbs of
        Left e -> lift $ logError $
          "Error processing Hackage security metadata for " <>
          fromString (Distribution.Text.display name) <> "-" <>
          fromString (Distribution.Text.display version) <> ": " <>
          fromString e
        Right (PackageDownload sha size) ->
          storeHackageTarballInfo name version sha size

    addCabal name version bs = do
      (blobTableId, _blobKey) <- storeBlob bs

      storeHackageRevision name version blobTableId

      -- Some older Stackage snapshots ended up with slightly
      -- modified cabal files, in particular having DOS-style
      -- line endings (CRLF) converted to Unix-style (LF). As a
      -- result, we track both hashes with and without CR
      -- characters stripped for compatibility with these older
      -- snapshots.
      --
      -- FIXME let's convert all old snapshots, correct the
      -- hashes, and drop this hack!
      let cr = 13
      when (cr `B.elem` bs) $ void $ storeBlob $ B.filter (/= cr) bs

    breakSlash x
        | T.null z = Nothing
        | otherwise = Just (y, unsafeTail z)
      where
        (y, z) = T.break (== '/') x

    parseNameVersionSuffix t1 = do
        (name, t2) <- breakSlash t1
        (version, filename) <- breakSlash t2

        name' <- Distribution.Text.simpleParse $ T.unpack name
        version' <- Distribution.Text.simpleParse $ T.unpack version

        Just (name', version', filename)

-- | Package download info from Hackage
data PackageDownload = PackageDownload !StaticSHA256 !Word
instance FromJSON PackageDownload where
    parseJSON = withObject "PackageDownload" $ \o1 -> do
        o2 <- o1 .: "signed"
        Object o3 <- o2 .: "targets"
        Object o4:_ <- return $ toList o3
        len <- o4 .: "length"
        hashes <- o4 .: "hashes"
        sha256' <- hashes .: "sha256"
        sha256 <-
          case mkStaticSHA256FromText sha256' of
            Left e -> fail $ "Invalid sha256: " ++ show e
            Right x -> return x
        return $ PackageDownload sha256 len

resolveCabalFileInfo
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> Version
  -> CabalFileInfo
  -> RIO env BlobTableId
resolveCabalFileInfo name ver cfi = do
  mres <- inner
  case mres of
    Just res -> pure res
    Nothing -> do
      let msg = "Could not find cabal file info for " <> displayPackageIdentifierRevision name ver cfi
      updated <- updateHackageIndex $ Just $ msg <> ", updating"
      mres' <- if updated then inner else pure Nothing
      case mres' of
        Nothing -> error $ T.unpack $ utf8BuilderToText msg -- FIXME proper exception
        Just res -> pure res
  where
    thd3 (_, _, x) = x
    inner = do
      revs <- withStorage $ loadHackagePackageVersion name ver
      pure $
        case cfi of
          CFIHash (CabalHash sha msize) -> listToMaybe $ mapMaybe
            (\(sha', size', bid) ->
               if sha' == sha && maybe True (== size') msize
                 then Just bid
                 else Nothing)
            (Map.elems revs)
          CFIRevision rev -> thd3 <$> Map.lookup rev revs
          CFILatest -> (thd3 . fst) <$> Map.maxView revs

withCachedTree
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> Version
  -> BlobTableId -- ^ cabal file contents
  -> RIO env (TreeSId, TreeKey, Tree)
  -> RIO env (TreeKey, Tree)
withCachedTree name ver bid inner = do
  mres <- withStorage $ loadHackageTree name ver bid
  case mres of
    Just res -> pure res
    Nothing -> do
      (tid, treekey, tree) <- inner
      withStorage $ storeHackageTree name ver bid tid
      pure (treekey, tree)

getHackageTarball
  :: (HasPantryConfig env, HasLogFunc env)
  => PackageName
  -> Version
  -> CabalFileInfo
  -> RIO env (TreeKey, Tree)
getHackageTarball name ver cfi = do
  cabalFile <- resolveCabalFileInfo name ver cfi
  withCachedTree name ver cabalFile $ do
    mpair <- withStorage $ loadHackageTarballInfo name ver
    (sha, size) <-
      case mpair of
        Just pair -> pure pair
        Nothing -> do
          let msg = "No cryptographic hash found for Hackage package " <>
                    fromString (Distribution.Text.display name) <> "-" <>
                    fromString (Distribution.Text.display ver)
          updated <- updateHackageIndex $ Just $ msg <> ", updating"
          mpair2 <-
            if updated
              then withStorage $ loadHackageTarballInfo name ver
              else pure Nothing
          case mpair2 of
            Nothing -> error $ T.unpack $ utf8BuilderToText msg -- FIXME nicer exceptions, or return an Either
            Just pair2 -> pure pair2
    pc <- view pantryConfigL
    let urlPrefix = hscDownloadPrefix $ pcHackageSecurity pc
        url = mconcat
          [ urlPrefix
          , "package/"
          , T.pack $ Distribution.Text.display name
          , "-"
          , T.pack $ Distribution.Text.display ver
          , ".tar.gz"
          ]
    getArchive url (Just sha) (Just size)