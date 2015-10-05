{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module WeiXin.PublicPlatform.Yesod.Model where

import ClassyPrelude.Yesod
import qualified Data.Conduit.List          as CL
import qualified Data.Set                   as Set
import Database.Persist.Quasi


import WeiXin.PublicPlatform.Types
import WeiXin.PublicPlatform.Class


wxppSubModelsDef ::
#if MIN_VERSION_persistent(2, 0, 0)
    [EntityDef]
#else
    [EntityDef SqlType]
#endif
wxppSubModelsDef = $(persistFileWith lowerCaseSettings "models")

share [mkPersist sqlSettings, mkMigrate "migrateAllWxppSubModels"]
                    $(persistFileWith lowerCaseSettings "models")


type WxppDbBackend = PersistEntityBackend WxppInMsgRecord

newtype WxppDbRunner = WxppDbRunner {
                                runWxppDB ::
                                    forall a m. (MonadIO m, MonadBaseControl IO m) =>
                                        ReaderT WxppDbBackend m a -> m a
                                }

instance WxppCacheBackend WxppDbRunner where
    wxppCacheGetAccessToken (WxppDbRunner run_db) app_id = do
        run_db $ do
            fmap
                (fmap $
                    ((flip AccessToken app_id . wxppCachedAccessTokenData) &&& wxppCachedAccessTokenExpiryTime) . entityVal)
                $
                selectFirst
                    [ WxppCachedAccessTokenApp ==. app_id ]
                    [ Desc WxppCachedAccessTokenCreatedTime ]

    wxppCacheAddAccessToken (WxppDbRunner run_db) atk expiry = do
        now <- liftIO getCurrentTime
        run_db $ do
            insert_ $ WxppCachedAccessToken
                            (accessTokenApp atk)
                            (accessTokenData atk)
                            expiry
                            now

    wxppCachePurgeAccessToken (WxppDbRunner run_db) expiry = do
        run_db $ do
            deleteWhere [ WxppCachedAccessTokenExpiryTime <=. expiry ]

    wxppCacheAddOAuthAccessToken (WxppDbRunner run_db) atk_p expiry = do
        now <- liftIO getCurrentTime
        run_db $ do
            rec_id <- insert $ WxppCachedOAuthToken app_id open_id atk rtk m_state expiry now
            insertMany_ $
                map (\x -> WxppCachedOAuthTokenScope rec_id x) $ toList scopes
        where
            app_id    = oauthAtkPAppID atk_p
            open_id   = oauthAtkPOpenID atk_p
            atk       = oauthAtkPRaw atk_p
            rtk       = oauthAtkPRtk atk_p
            scopes    = oauthAtkPScopes atk_p
            m_state   = oauthAtkPState atk_p

    wxppCacheGetOAuthAccessToken (WxppDbRunner run_db) app_id open_id req_scopes m_state = do
        now <- liftIO getCurrentTime
        runResourceT $ run_db $ do
            selectSource
                    [ WxppCachedOAuthTokenApp ==. app_id
                    , WxppCachedOAuthTokenOpenId ==. open_id
                    , WxppCachedOAuthTokenState ==. m_state
                    , WxppCachedOAuthTokenExpiryTime >. now
                    ]
                    [ Desc WxppCachedOAuthTokenId ]
                =$= check_scopes
                $$ CL.head
        where
            check_scopes = awaitForever $ \(Entity rec_id rec) -> do
                has_scopes <- lift $
                                liftM (Set.fromList .
                                        (map $  wxppCachedOAuthTokenScopeScope . entityVal)
                                    ) $
                                    selectList [ WxppCachedOAuthTokenScopeToken ==. rec_id ] []
                when ( Set.isSubsetOf req_scopes has_scopes ) $ do
                    yield $ mk_p rec has_scopes

            mk_p rec scopes = OAuthTokenInfo
                                (wxppCachedOAuthTokenAccess rec)
                                (wxppCachedOAuthTokenRefresh rec)
                                scopes
                                (wxppCachedOAuthTokenState rec)
                                (wxppCachedOAuthTokenExpiryTime rec)

    wxppCachePurgeOAuthAccessToken (WxppDbRunner run_db) expiry = do
        run_db $
            deleteWhere [ WxppCachedOAuthTokenExpiryTime <=. expiry ]

    wxppCacheLookupUserInfo (WxppDbRunner run_db) app_id open_id = do
        run_db $ do
            fmap
                (fmap $
                    (fromWxppCachedUserInfoExt &&& wxppCachedUserInfoExtCreatedTime) .
                    entityVal
                ) $
                getBy $ UniqueWxppCachedUserInfoExt open_id app_id

    wxppCacheSaveUserInfo (WxppDbRunner run_db) app_id qres = do
        now <- liftIO getCurrentTime
        run_db $ do
            case toWxppCachedUserInfoExt app_id now qres of
                Nothing -> do
                    -- 用户不再关注
                    -- 暂时不删除缓存
                    return ()

                Just rec -> do
                    insertBy rec
                        >>= either (flip replace rec . entityKey) (const $ return ())

    wxppCacheLookupUploadedMediaIDByHash (WxppDbRunner run_db) app_id h = do
        run_db $ do
            m_rec <- getBy $ UniqueWxppCachedUploadedMediaHash h app_id
            case entityVal <$> m_rec of
                Nothing -> return Nothing
                Just (WxppCachedUploadedMedia _app_id _md5 mtype mid ctime) -> do
                    return $ Just $ UploadResult mtype mid ctime

    wxppCacheSaveUploadedMediaID
        (WxppDbRunner run_db) app_id h (UploadResult mtype mid ctime) = do
        run_db $ do
            let rec = WxppCachedUploadedMedia app_id h mtype mid ctime
            insertBy rec >>= either (flip replace rec . entityKey) (const $ return ())


fromWxppCachedUserInfoExt :: WxppCachedUserInfoExt -> EndUserQueryResult
fromWxppCachedUserInfoExt
    (WxppCachedUserInfoExt
        _app_id
        open_id
        m_union_id
        nickname
        m_gender
        locale
        city
        province
        country
        head_img
        subs_time
        _create_time)
    = EndUserQueryResult
        open_id
        nickname
        m_gender
        locale
        city
        province
        country
        head_img
        subs_time
        m_union_id

toWxppCachedUserInfoExt :: WxppAppID -> UTCTime -> EndUserQueryResult -> Maybe WxppCachedUserInfoExt
toWxppCachedUserInfoExt _ _ (EndUserQueryResultNotSubscribed {}) = Nothing
toWxppCachedUserInfoExt app_id created_time
    (EndUserQueryResult
        open_id
        nickname
        m_gender
        locale
        city
        province
        country
        head_img
        subs_time
        m_union_id)
    = Just $ WxppCachedUserInfoExt
        app_id
        open_id
        m_union_id
        nickname
        m_gender
        locale
        city
        province
        country
        head_img
        subs_time
        created_time

