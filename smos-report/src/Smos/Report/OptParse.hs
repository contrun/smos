{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Report.OptParse where

import System.Environment
import System.Exit

import Control.Monad

import qualified Data.Text.IO as T

import Data.Aeson as JSON (eitherDecodeFileStrict)
import Data.Aeson (FromJSON)
import Data.Yaml as Yaml
       (decodeFileEither, prettyPrintParseException)
import Dhall

import Path
import Path.IO

import Smos.Report.Config

import Options.Applicative

import Smos.Report.OptParse.Types

combineToConfig ::
       SmosReportConfig
    -> Flags
    -> Environment
    -> Maybe Configuration
    -> IO SmosReportConfig
combineToConfig src Flags {..} Environment {..} mc = do
    pure $
        case msum [flagWorkflowDir, envWorkflowDir, mc >>= confWorkflowDir] of
            Nothing -> src
            Just wd ->
                src
                { smosReportConfigAgendaFileSpec =
                      AgendaFileSpec $ resolveDir' wd
                }

parseFlags :: Parser Flags
parseFlags = Flags <$> parseWorkflowDirFlag

parseWorkflowDirFlag :: Parser (Maybe FilePath)
parseWorkflowDirFlag =
    option
        (Just <$> str)
        (mconcat
             [ metavar "FILEPATH"
             , help "The workflow directory to use"
             , value Nothing
             ])

getEnv :: IO Environment
getEnv = do
    env <- getEnvironment
    let getSmosEnv :: String -> Maybe String
        getSmosEnv key = ("SMOS_" ++ key) `lookup` env
    pure
        Environment
        { envWorkflowDir =
              getSmosEnv "WORKFLOW_DIRECTORY" <|> getSmosEnv "WORKFLOW_DIR"
        }

defaultDhallConfigFile :: IO (Maybe (Path Abs File))
defaultDhallConfigFile = do
    home <- getHomeDir
    p <- resolveFile home ".smos.dhall"
    e <- doesFileExist p
    pure $
        if e
            then Just p
            else Nothing

defaultJSONConfigFile :: IO (Maybe (Path Abs File))
defaultJSONConfigFile = do
    home <- getHomeDir
    p <- resolveFile home ".smos.json"
    e <- doesFileExist p
    pure $
        if e
            then Just p
            else Nothing

defaultYamlConfigFile :: IO (Maybe (Path Abs File))
defaultYamlConfigFile = do
    home <- getHomeDir
    p <- resolveFile home ".smos.yaml"
    e <- doesFileExist p
    pure $
        if e
            then Just p
            else Nothing

parseDhallConfig :: Dhall.Type a -> Text -> Path Abs File -> IO a
parseDhallConfig configType configDefaults configFile = do
    contents <- T.readFile $ fromAbsFile configFile
    detailed (input configType (configDefaults <> "//" <> contents))

parseYamlConfig :: FromJSON a => Path Abs File -> IO a
parseYamlConfig configFile = do
    errOrConfig <- decodeFileEither $ fromAbsFile configFile
    case errOrConfig of
        Left err -> die $ prettyPrintParseException err
        Right config -> pure config

parseJSONConfig :: FromJSON a => Path Abs File -> IO a
parseJSONConfig configFile = do
    errOrConfig <- JSON.eitherDecodeFileStrict $ fromAbsFile configFile
    case errOrConfig of
        Left err -> die err
        Right config -> pure config

getConfigurationWith ::
       FromJSON a => [Maybe FilePath] -> Text -> Dhall.Type a -> IO (Maybe a)
getConfigurationWith mConfigFileOverrides configDefaults configType = do
    mConfigFile <-
        case msum mConfigFileOverrides of
            Nothing ->
                msum <$>
                Control.Monad.sequence
                    [ defaultDhallConfigFile
                    , defaultYamlConfigFile
                    , defaultJSONConfigFile
                    ]
            Just fp -> Just <$> resolveFile' fp
    forM mConfigFile $ \configFile ->
        case fileExtension configFile of
            ".dhall" -> parseDhallConfig configType configDefaults configFile
            ".json" -> parseJSONConfig configFile
            -- As Yaml
            _ -> parseYamlConfig configFile
