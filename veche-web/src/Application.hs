{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -fno-warn-orphans #-} -- instance YesodDispatch App

module Application
    ( getApplicationDev
    , appMain
    , develMain
    , makeFoundation
    , makeLogWare
    -- * for DevelMain
    , getApplicationRepl
    , shutdownApp
    -- * for GHCI
    , handler
    , db
    ) where

import Import

-- global
import Control.Monad.Logger (liftLoc, runLoggingT)
import Data.Text qualified as Text
import Database.Persist.Sqlite (Single, createSqlitePool, printMigration,
                                rawSql, runSqlPool, sqlDatabase, sqlPoolSize)
import Language.Haskell.TH.Syntax (qLocation)
import Network.HTTP.Client.TLS (getGlobalManager)
import Network.Wai (Middleware)
import Network.Wai.Handler.Warp (Settings, defaultSettings,
                                 defaultShouldDisplayException, getPort,
                                 runSettings, setHost, setOnException, setPort)
import Network.Wai.Middleware.RequestLogger (Destination (Logger),
                                             IPAddrSource (FromFallback, FromSocket),
                                             OutputFormat (Apache, Detailed),
                                             destination, mkRequestLogger,
                                             outputFormat)
import Servant.Client (parseBaseUrl)
import System.Log.FastLogger (defaultBufSize, newStdoutLoggerSet, toLogStr)

-- component
import Handler.Admin (getAdminUpdateDatabaseR)
import Handler.API (getApiCompleteUserR)
import Handler.Comment (postCommentsR)
import Handler.Common (getFaviconR, getRobotsR)
import Handler.Dashboard (getDashboardR)
import Handler.Issue (getIssueEditR, getIssueNewR, getIssueR, getIssuesR,
                      postIssueR, postIssuesR)
import Handler.User (getUserR, putUserR)
import Workers.StellarUpdate (stellarDataUpdater)

-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see the
-- comments there for more details.
mkYesodDispatch "App" resourcesApp

-- | This function allocates resources (such as a database connection pool),
-- performs initialization and returns a foundation datatype value. This is also
-- the place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
makeFoundation :: AppSettings -> IO App
makeFoundation appSettings = do
    -- Some basic initializations: HTTP connection manager, logger, and static
    -- subsite.
    appHttpManager <- getGlobalManager
    appLogger <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
    appStatic <- (if appMutableStatic then staticDevel else static) appStaticDir

    appStellarHorizon <- parseBaseUrl $ Text.unpack appStellarHorizonUrl

    -- We need a log function to create a connection pool. We need a connection
    -- pool to create our foundation. And we need our foundation to get a
    -- logging function. To get out of this loop, we initially create a
    -- temporary foundation without a real connection pool, get a log function
    -- from there, and then create the real foundation.
    let mkFoundation appConnPool =
            App { appSettings
                , appStatic
                , appConnPool
                , appHttpManager
                , appLogger
                , appStellarHorizon
                }
        tempFoundation =
            mkFoundation $ error "connPool forced in tempFoundation"
        logFunc = messageLoggerSource tempFoundation appLogger

    -- Create the database connection pool
    pool <- (`runLoggingT` logFunc) $ createSqlitePool database poolSize

    -- Perform database migration using our application's logging settings.
    (`runLoggingT` logFunc) $
        (`runSqlPool` pool) do
            userTableNameAsList :: [Single Text] <-
                rawSql
                    "SELECT name FROM sqlite_master\
                        \ WHERE type='table' AND name='user'"
                    []
            let databaseIsEmpty = null userTableNameAsList
            if appDatabaseMigrate || databaseIsEmpty then
                runMigration migrateAll
            else do
                putStrLn "NOT MIGRATING, but we have something to migrate:"
                printMigration migrateAll

    -- Return the foundation
    pure $ mkFoundation pool

  where
    AppSettings
        { appDatabaseMigrate
        , appDatabaseConf
        , appMutableStatic
        , appStaticDir
        , appStellarHorizonUrl
        } =
            appSettings
    database = sqlDatabase appDatabaseConf
    poolSize = sqlPoolSize appDatabaseConf

-- | Convert our foundation to a WAI Application by calling @toWaiAppPlain@ and
-- applying some additional middlewares.
makeApplication :: App -> IO Application
makeApplication foundation = do
    logWare <- makeLogWare foundation
    -- Create the WAI application and apply middlewares
    appPlain <- toWaiAppPlain foundation
    pure $ logWare $ defaultMiddlewaresNoLogging appPlain

makeLogWare :: App -> IO Middleware
makeLogWare foundation =
    mkRequestLogger
        def { outputFormat =
                if appDetailedRequestLogging $ appSettings foundation then
                    Detailed True
                else
                    Apache $
                        if appIpFromHeader $ appSettings foundation then
                            FromFallback
                        else
                            FromSocket
            , destination = Logger $ loggerSet $ appLogger foundation
            }


-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
    defaultSettings
    & setHost appHost
    & setPort appPort
    & setOnException
        (\_req e ->
            when (defaultShouldDisplayException e) $
                messageLoggerSource
                    foundation
                    appLogger
                    $(qLocation >>= liftLoc)
                    "yesod"
                    LevelError
                    (toLogStr $ "Exception from Warp: " ++ show e))
  where
    App{appLogger, appSettings = AppSettings{appPort, appHost}} = foundation

-- | For yesod devel, pure the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
    settings <- getAppSettings
    let settings' =
            settings
            { appAuthDummyLogin         = True
            , appDetailedRequestLogging = True
            , appMutableStatic          = True
            , appReloadTemplates        = True
            , appShouldLogAll           = True
            , appSkipCombining          = True
            }
    foundation <- makeFoundation settings'
    wsettings <- getDevSettings $ warpSettings foundation
    app <- makeApplication foundation
    pure (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain = do
    -- Get the settings from all relevant sources
    settings <-
        loadYamlSettingsArgs
            -- fall back to compile-time values, set to [] to require values
            -- at runtime
            [configSettingsYmlValue]

            -- allow environment variables to override
            useEnv

    -- Generate the foundation from the settings
    foundation@App{appConnPool, appStellarHorizon} <- makeFoundation settings

    -- Generate a WAI Application from the foundation
    app <- makeApplication foundation

    -- Backend workers
    async (stellarDataUpdater appStellarHorizon appConnPool) >>= link

    -- Run the application with Warp
    runSettings (warpSettings foundation) app


--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
    settings <- getAppSettings
    foundation <- makeFoundation settings
    wsettings <- getDevSettings $ warpSettings foundation
    app1 <- makeApplication foundation
    pure (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = pure ()


---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------

-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= (`unsafeHandler` h)

-- | Run DB queries
db :: ReaderT SqlBackend Handler a -> IO a
db = handler . runDB
