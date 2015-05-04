{-# LANGUAGE TupleSections #-}
module WeiXin.PublicPlatform.InMsgHandler where

import ClassyPrelude
import Data.Proxy
import Control.Monad.Logger
import Control.Monad.Trans.Except
import qualified Data.Text                  as T
import qualified Data.ByteString.Lazy       as LB
import Data.Aeson
import Data.Aeson.Types                     (Parser)
import Data.Yaml                            (decodeFileEither, parseEither, ParseException(..))

import Text.Regex.TDFA                      (blankExecOpt, blankCompOpt, Regex)
import Text.Regex.TDFA.TDFA                 ( examineDFA)
import Text.Regex.TDFA.String               (compile, execute)
import Filesystem.Path.CurrentOS            (encodeString, fromText, extension)
import qualified Filesystem.Path.CurrentOS  as FP

import Yesod.Helpers.Aeson                  (parseArray)

import WeiXin.PublicPlatform.Types
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Media
import WeiXin.PublicPlatform.Acid


-- | 对收到的消息处理的函数
type WxppInMsgProcessor m a =
        LB.ByteString
            -- ^ raw data of message (unparsed)
        -> Maybe WxppInMsgEntity
            -- ^ this is nothing only if caller cannot parse the message
        -> m (Either String a)
            -- ^ Left 用于表达错误

-- | 对于收到的消息有的回应，可能有多个。
-- 分为两类：主要的，和备选的
-- 备选的回应仅当“主要的”回应不存在是使用
-- 主要的回应如果有多个，会尽量全部发给用户。但由于微信接口的限制，只有
-- 第一个回应可以以回复的方式发给用户，其它“主要”回应要通过“客服”接口发给
-- 用户，而“客服”接口需要一定条件才能开通。
-- Bool 表明这个响应是否是“主要”的
-- Nothing 代表无需回复一个新信息
type WxppInMsgHandlerResult = [(Bool, Maybe WxppOutMsg)]

type WxppInMsgHandler m = WxppInMsgProcessor m WxppInMsgHandlerResult


-- | 可以从配置文件中读取出来的某种处理值
class JsonConfigable h where
    -- | 从配置文件中读取的数据未必能提供构造完整的值的所有信息
    -- 这个类型指示出无法在配置文件中提供的信息
    -- 这部分信息只能由调用者自己提供
    -- 通常这会是一个函数
    type JsonConfigableUnconfigData h

    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler :: Proxy h -> Text -> Bool

    parseWithExtraData :: Proxy h -> JsonConfigableUnconfigData h -> Object -> Parser h


-- | 预处理收到的消息的结果
type family WxppInMsgProcessResult h :: *


-- | 对收到的消息作出某种处理
-- 实例分为两大类：
-- Predictor 其处理结果是个 Bool 值
-- Handler 其处理结果是个 WxppInMsgHandlerResult
class IsWxppInMsgProcessor m h where
    processInMsg ::
        h
        -> AcidState WxppAcidState
        -> m (Maybe AccessToken)
        -> WxppInMsgProcessor m (WxppInMsgProcessResult h)

data SomeWxppInMsgProcessor r m =
        forall h. (IsWxppInMsgProcessor m h, WxppInMsgProcessResult h ~ r) => SomeWxppInMsgProcessor h

type instance WxppInMsgProcessResult (SomeWxppInMsgProcessor r m) = r

-- | 所有 Handler 可放在这个类型内
type SomeWxppInMsgHandler m = SomeWxppInMsgProcessor WxppInMsgHandlerResult m

-- | 所有 Predictor 可放在这个类型内
type SomeWxppInMsgPredictor m = SomeWxppInMsgProcessor Bool m


-- | something that can be used as WxppInMsgHandler
type IsWxppInMsgHandler m h =
        ( IsWxppInMsgProcessor m h
        , WxppInMsgProcessResult h ~ WxppInMsgHandlerResult
        )

instance IsWxppInMsgProcessor m (SomeWxppInMsgProcessor r m) where
    processInMsg (SomeWxppInMsgProcessor h) = processInMsg h


data WxppInMsgProcessorPrototype r m =
        forall h. (IsWxppInMsgProcessor m h, JsonConfigable h, WxppInMsgProcessResult h ~ r) =>
                WxppInMsgProcessorPrototype (Proxy h) (JsonConfigableUnconfigData h)

type WxppInMsgHandlerPrototype m = WxppInMsgProcessorPrototype WxppInMsgHandlerResult m

type WxppInMsgPredictorPrototype m = WxppInMsgProcessorPrototype Bool m

type IsWxppInMsgHandlerRouter m p =
            ( IsWxppInMsgProcessor m p, JsonConfigable p
            , WxppInMsgProcessResult p ~ Maybe (SomeWxppInMsgHandler m)
            )

data SomeWxppInMsgHandlerRouter m =
        forall p. ( IsWxppInMsgHandlerRouter m p ) =>
            SomeWxppInMsgHandlerRouter p


-- | 用于在配置文件中，读取出一系列响应算法
parseWxppInMsgProcessors ::
    [WxppInMsgProcessorPrototype r m]
    -> Value
    -> Parser [SomeWxppInMsgProcessor r m]
parseWxppInMsgProcessors known_hs = withArray "[SomeWxppInMsgProcessor]" $
        mapM (withObject "SomeWxppInMsgProcessor" $ parseWxppInMsgProcessor known_hs) . toList

parseWxppInMsgProcessor ::
    [WxppInMsgProcessorPrototype r m]
    -> Object
    -> Parser (SomeWxppInMsgProcessor r m)
parseWxppInMsgProcessor known_hs obj = do
        name <- obj .: "name"
        WxppInMsgProcessorPrototype ph ext <- maybe
                (fail $ "unknown processor name: " <> T.unpack name)
                return
                $ flip find known_hs
                $ \(WxppInMsgProcessorPrototype ph _) -> isNameOfInMsgHandler ph name
        fmap SomeWxppInMsgProcessor $ parseWithExtraData ph ext obj


readWxppInMsgHandlers ::
    [WxppInMsgHandlerPrototype m]
    -> String
    -> IO (Either ParseException [SomeWxppInMsgHandler m])
readWxppInMsgHandlers tmps fp = runExceptT $ do
    (ExceptT $ decodeFileEither fp)
        >>= either (throwE . AesonException) return
                . parseEither (parseWxppInMsgProcessors tmps)


-- | 使用列表里的所有算法，逐一调用一次以处理收到的信息
tryEveryInMsgHandler :: MonadLogger m =>
    [WxppInMsgHandler m] -> WxppInMsgHandler m
tryEveryInMsgHandler handlers bs m_ime = do
    (errs, res_lst) <- liftM partitionEithers $
                            mapM (\h -> h bs m_ime) handlers
    forM_ errs $ \err -> do
        $(logWarnS) wxppLogSource $ T.pack $
            "Error when handling incoming message, "
            <> "MsgId=" <> (show $ join $ fmap wxppInMessageID m_ime)
            <> ": " <> err

    return $ Right $ join res_lst


tryEveryInMsgHandler' :: MonadLogger m =>
    AcidState WxppAcidState
    -> m (Maybe AccessToken)
    -> [SomeWxppInMsgHandler m]
    -> WxppInMsgHandler m
tryEveryInMsgHandler' acid get_atk known_hs = do
    tryEveryInMsgHandler $ flip map known_hs $ \h -> processInMsg h acid get_atk

tryWxppWsResultE :: MonadCatch m =>
    String -> ExceptT String m b -> ExceptT String m b
tryWxppWsResultE op f =
    tryWxppWsResult f
        >>= either (\e -> throwE $ "Got Exception when " <> op <> ": " <> show e) return


parseWxppOutMsgLoader :: Object -> Parser WxppOutMsgLoader
parseWxppOutMsgLoader obj =
    (return . Right <$> obj .: "msg") <|>
        (decodeOutMsgFile . setExtIfNotExist "yml" . fromText <$> obj .: "file")

decodeOutMsgFile :: FilePath -> WxppOutMsgLoader
decodeOutMsgFile fp = do
    msg_dir <- ask
    liftIO $ decodeFileEither (encodeString $ msg_dir </> fp)


-- | 执行 WxppOutMsgLoader 的操作，把结果转换成 WxppInMsgProcessor 所需的格式
runWxppOutMsgLoader :: MonadIO m =>
    FilePath    -- ^ 消息文件存放目录
    -> WxppOutMsgLoader
    -> m (Either String WxppOutMsgL)
runWxppOutMsgLoader msg_dir get_outmsg = liftIO $ do
    err_or_msg <- tryIOError $ runReaderT get_outmsg msg_dir
    case err_or_msg of
        Left err    -> return $ Left $ "failed to load message from file: " ++ show err
        Right x     -> return $ parseMsgErrorToString x

parseMsgErrorToString :: Either ParseException a -> Either String a
parseMsgErrorToString (Left err)   = Left $ "failed to parse message from file: " ++ show err
parseMsgErrorToString (Right x)    = Right x


-- | Handler: 处理收到的信息的算法例子：用户订阅公众号时发送欢迎信息
data WelcomeSubscribe = WelcomeSubscribe
                            FilePath            -- ^ 所有消息文件存放的目录
                            WxppOutMsgLoader    -- ^ 打算回复用户的消息
                        deriving (Typeable)

instance JsonConfigable WelcomeSubscribe where
    type JsonConfigableUnconfigData WelcomeSubscribe = FilePath

    isNameOfInMsgHandler _ x = x == "welcome-subscribe"

    parseWithExtraData _ msg_dir obj = do
        WelcomeSubscribe msg_dir <$> parseWxppOutMsgLoader obj


type instance WxppInMsgProcessResult WelcomeSubscribe = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m) =>
    IsWxppInMsgProcessor m WelcomeSubscribe
    where

    processInMsg (WelcomeSubscribe msg_dir get_outmsg) acid get_atk _bs m_ime = runExceptT $ do
        is_subs <- case fmap wxppInMessage m_ime of
                    Just (WxppInMsgEvent WxppEvtSubscribe)              -> return True
                    Just (WxppInMsgEvent (WxppEvtSubscribeAtScene {}))  -> return True
                    _                                                   -> return False
        if is_subs
            then do
                atk <- (tryWxppWsResultE "getting access token" $ lift get_atk)
                        >>= maybe (throwE $ "no access token available") return
                outmsg <- ExceptT $ runWxppOutMsgLoader msg_dir get_outmsg
                liftM (return . (True,) . Just) $ tryWxppWsResultE "fromWxppOutMsgL" $
                                fromWxppOutMsgL acid atk outmsg
            else return []


-- | Handler: 处理点击菜单项目的事件通知，加载 Key 参数中指定的文件所记录的消息
-- 要求 Key 参数的格式为： send-msg:<path to yaml>
data WxppInMsgMenuItemClickSendMsg = WxppInMsgMenuItemClickSendMsg FilePath

instance JsonConfigable WxppInMsgMenuItemClickSendMsg where
    type JsonConfigableUnconfigData WxppInMsgMenuItemClickSendMsg = FilePath

    isNameOfInMsgHandler _ x = x == "menu-click-send-msg"

    parseWithExtraData _ msg_dir _obj = return $ WxppInMsgMenuItemClickSendMsg msg_dir


type instance WxppInMsgProcessResult WxppInMsgMenuItemClickSendMsg = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m) =>
    IsWxppInMsgProcessor m WxppInMsgMenuItemClickSendMsg
    where

    processInMsg (WxppInMsgMenuItemClickSendMsg msg_dir) acid get_atk _bs m_ime = runExceptT $ do
        let m_fp = do
                in_msg <- fmap wxppInMessage m_ime
                case in_msg of
                    WxppInMsgEvent (WxppEvtClickItem evt_key) -> do
                            T.stripPrefix "send-msg:" evt_key

                    _ -> Nothing

        case m_fp of
            Nothing -> return []
            Just fp' -> do
                atk <- (tryWxppWsResultE "getting access token" $ lift get_atk)
                        >>= maybe (throwE $ "no access token available") return
                let fp = setExtIfNotExist "yml" $ fromText fp'
                outmsg <- ExceptT $ runWxppOutMsgLoader msg_dir $ decodeOutMsgFile fp
                liftM (return . (True,) . Just) $ tryWxppWsResultE "fromWxppOutMsgL" $
                                fromWxppOutMsgL acid atk outmsg


-- | Handler: 回复原文本消息中路径指定的任意消息
-- 为安全计，要保证文件的真实路径在约定的目录下
-- 另外，还要求设置一个简单的口令作为前缀，同时也作为识别
data WxppInMsgSendAsRequested = WxppInMsgSendAsRequested FilePath Text

instance JsonConfigable WxppInMsgSendAsRequested where
    type JsonConfigableUnconfigData WxppInMsgSendAsRequested = FilePath

    isNameOfInMsgHandler _ x = x == "as-you-request"

    parseWithExtraData _ msg_dir obj = WxppInMsgSendAsRequested msg_dir <$> obj .: "magic-word"


type instance WxppInMsgProcessResult WxppInMsgSendAsRequested = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m) =>
    IsWxppInMsgProcessor m WxppInMsgSendAsRequested
    where

    processInMsg (WxppInMsgSendAsRequested msg_dir magic_word) acid get_atk _bs m_ime = runExceptT $ do
        let m_fp = do
                in_msg <- fmap wxppInMessage m_ime
                case in_msg of
                    WxppInMsgText content -> do
                        fp <- fromText . T.strip <$> T.stripPrefix (magic_word <> " ") content
                        fp2 <- FP.stripPrefix msg_dir (FP.collapse (msg_dir </> fp))
                        when (fp /= fp2) mzero
                        return fp

                    _ -> Nothing

        case m_fp of
            Nothing -> return []
            Just fp -> do
                atk <- (tryWxppWsResultE "getting access token" $ lift get_atk)
                        >>= maybe (throwE $ "no access token available") return
                outmsg <- ExceptT $ runWxppOutMsgLoader msg_dir $ decodeOutMsgFile fp
                liftM (return . (True,) . Just) $ tryWxppWsResultE "fromWxppOutMsgL" $
                                fromWxppOutMsgL acid atk outmsg


-- | Handler: 根据所带的 Predictor 与 Handler 对应表，分发到不同的 Handler 处理收到消息
data WxppInMsgDispatchHandler m =
        WxppInMsgDispatchHandler [(SomeWxppInMsgPredictor m, SomeWxppInMsgHandler m)]

instance Show (WxppInMsgDispatchHandler m) where
    show _ = "WxppInMsgDispatchHandler"

instance JsonConfigable (WxppInMsgDispatchHandler m) where
    type JsonConfigableUnconfigData (WxppInMsgDispatchHandler m) =
            ( [WxppInMsgPredictorPrototype m]
            , [WxppInMsgHandlerPrototype m]
            )

    isNameOfInMsgHandler _ x = x == "dispatch"

    parseWithExtraData _ (proto_pred, proto_handler) obj = do
        fmap WxppInMsgDispatchHandler $
            obj .: "route" >>= parseArray "message handler routes" parse_one
        where
            parse_one = withObject "message handler route" $ \o -> do
                p <- o .: "predictor" >>= parseWxppInMsgProcessor proto_pred
                h <- o .: "handler" >>= parseWxppInMsgProcessor proto_handler
                return $ (p, h)


type instance WxppInMsgProcessResult (WxppInMsgDispatchHandler m) = WxppInMsgHandlerResult

instance (Monad m, MonadLogger m) => IsWxppInMsgProcessor m (WxppInMsgDispatchHandler m)
    where
    processInMsg (WxppInMsgDispatchHandler table) acid get_atk bs m_ime =
        go table
        where
            go []               = return $ Right []
            go ((p, h):xs)      = do
                err_or_b <- processInMsg p acid get_atk bs m_ime
                b <- case err_or_b of
                    Left err -> do
                                $(logErrorS) wxppLogSource $ fromString $
                                    "Predictor failed: " <> err
                                return False
                    Right b -> return b
                if b
                    then processInMsg h acid get_atk bs m_ime
                    else go xs


-- | Handler: 将满足某些条件的用户信息转发至微信的“多客服”系统
data TransferToCS = TransferToCS Bool
                    deriving (Show, Typeable)

instance JsonConfigable TransferToCS where
    type JsonConfigableUnconfigData TransferToCS = ()

    isNameOfInMsgHandler _ x = x == "transfer-to-cs"

    parseWithExtraData _ _ obj = TransferToCS <$> obj .:? "primary" .!= False


type instance WxppInMsgProcessResult TransferToCS = WxppInMsgHandlerResult

instance (Monad m) => IsWxppInMsgProcessor m TransferToCS where
    processInMsg (TransferToCS is_primary) _acid _get_atk _bs _m_ime =
        return $ Right $ return $ (is_primary,) $ Just WxppOutMsgTransferToCustomerService


-- | Predictor: 判断信息是否是指定列表里的字串之一
-- 注意：用户输入去除空白之后，必须完整地匹配列表中某个元素才算匹配
data WxppInMsgMatchOneOf = WxppInMsgMatchOneOf [Text]
                            deriving (Show, Typeable)


instance JsonConfigable WxppInMsgMatchOneOf where
    type JsonConfigableUnconfigData WxppInMsgMatchOneOf = ()

    isNameOfInMsgHandler _ x = x == "one-of"

    parseWithExtraData _ _ obj = (WxppInMsgMatchOneOf . map T.strip) <$> obj .: "texts"


type instance WxppInMsgProcessResult WxppInMsgMatchOneOf = Bool

instance (Monad m) => IsWxppInMsgProcessor m WxppInMsgMatchOneOf where
    processInMsg (WxppInMsgMatchOneOf lst) _acid _get_atk _bs m_ime = runExceptT $ do
        case wxppInMessage <$> m_ime of
            Just (WxppInMsgText t)  -> return $ T.strip t `elem` lst
            _                       -> return False

-- | Predictor: 判断信息是否是指定列表里的字串之一
-- 注意：用户输入去除空白之后，必须完整地匹配列表中某个元素才算匹配
data WxppInMsgMatchOneOfRe = WxppInMsgMatchOneOfRe [Regex]
                            deriving (Typeable)

instance Show WxppInMsgMatchOneOfRe where
    show (WxppInMsgMatchOneOfRe res) =
        "WxppInMsgMatchOneOfRe " ++ show (map examineDFA res)

instance JsonConfigable WxppInMsgMatchOneOfRe where
    type JsonConfigableUnconfigData WxppInMsgMatchOneOfRe = ()

    isNameOfInMsgHandler _ x = x == "one-of-posix-re"

    parseWithExtraData _ _ obj = do
        re_list <- obj .: "re"
        fmap WxppInMsgMatchOneOfRe $ forM re_list $ \r -> do
            case compile blankCompOpt blankExecOpt r of
                Left err -> fail $ "Failed to compile RE: " <> err
                Right rx -> return rx

type instance WxppInMsgProcessResult WxppInMsgMatchOneOfRe = Bool

instance (Monad m) => IsWxppInMsgProcessor m WxppInMsgMatchOneOfRe where
    processInMsg (WxppInMsgMatchOneOfRe lst) _acid _get_atk _bs m_ime = runExceptT $ do
        case wxppInMessage <$> m_ime of
            Just (WxppInMsgText t')  -> do
                let t = T.unpack $ T.strip t'
                return $ not $ null $ catMaybes $ rights $ map (flip execute t) lst
            _                       -> return False


-- | Handler: 固定地返回一个某个信息
data ConstResponse = ConstResponse FilePath Bool WxppOutMsgLoader
                    deriving (Typeable)

instance JsonConfigable ConstResponse where
    type JsonConfigableUnconfigData ConstResponse = FilePath

    isNameOfInMsgHandler _ x = x == "const"

    parseWithExtraData _ msg_dir obj = do
        liftM2 (ConstResponse msg_dir)
            (obj .:? "primary" .!= False)
            (parseWxppOutMsgLoader obj)


type instance WxppInMsgProcessResult ConstResponse = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m) =>
    IsWxppInMsgProcessor m ConstResponse
    where

    processInMsg (ConstResponse msg_dir is_primary get_outmsg) acid get_atk _bs _m_ime = runExceptT $ do
        atk <- (tryWxppWsResultE "getting access token" $ lift get_atk)
                >>= maybe (throwE $ "no access token available") return
        outmsg <- ExceptT $ runWxppOutMsgLoader msg_dir get_outmsg
        liftM (return . (is_primary,) . Just) $ tryWxppWsResultE "fromWxppOutMsgL" $
                        fromWxppOutMsgL acid atk outmsg


-- | 用于解释 SomeWxppInMsgHandler 的类型信息
allBasicWxppInMsgHandlerPrototypes ::
    ( MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m ) =>
    FilePath
    -> [WxppInMsgHandlerPrototype m]
allBasicWxppInMsgHandlerPrototypes msg_dir =
    [ WxppInMsgProcessorPrototype (Proxy :: Proxy WelcomeSubscribe) msg_dir
    , WxppInMsgProcessorPrototype (Proxy :: Proxy WxppInMsgMenuItemClickSendMsg) msg_dir
    , WxppInMsgProcessorPrototype (Proxy :: Proxy WxppInMsgSendAsRequested) msg_dir
    , WxppInMsgProcessorPrototype (Proxy :: Proxy TransferToCS) ()
    , WxppInMsgProcessorPrototype (Proxy :: Proxy ConstResponse) msg_dir
    ]


-- | 用于解释 SomeWxppInMsgPredictor 的类型信息
allBasicWxppInMsgPredictorPrototypes ::
    ( MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m ) =>
    [WxppInMsgPredictorPrototype m]
allBasicWxppInMsgPredictorPrototypes =
    [ WxppInMsgProcessorPrototype (Proxy :: Proxy WxppInMsgMatchOneOf) ()
    , WxppInMsgProcessorPrototype (Proxy :: Proxy WxppInMsgMatchOneOfRe) ()
    ]

--------------------------------------------------------------------------------

setExtIfNotExist :: Text -> FilePath -> FilePath
setExtIfNotExist def_ext fp =
    maybe (fp <.> def_ext) (const fp) $ extension fp
