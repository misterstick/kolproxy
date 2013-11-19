module KoL.Util where

import Prelude hiding (read, catch)
import KoL.UtilTypes
import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.List
import Data.Maybe
import Data.Typeable
import Network.CGI (formDecode)
import Network.URI (parseURIReference, uriQuery)
import System.Directory
import System.Environment
import System.FilePath
import Text.Regex.TDFA
import qualified Data.ByteString.Char8
import qualified Data.ByteString.Lazy.Char8
import qualified Data.Digest.Pure.MD5
import qualified Database.SQLite3Modded


kolproxy_version_number = "3.18-beta"

kolproxy_version_string = "kolproxy/" ++ kolproxy_version_number

get_md5 str = show $ Data.Digest.Pure.MD5.md5 $ Data.ByteString.Lazy.Char8.pack str




matchGroups :: String -> String -> [[String]]
matchGroups regex text = map tail $ (match rx text :: [[String]])
	where rx = (makeRegexOpts blankCompOpt blankExecOpt regex) :: Regex

read_as str = case reads str of
	[(x, "")] -> Just x
	[(x, "\n")] -> Just x
	_ -> Nothing

read_e x = let y = read_as x in
	case y of
		Just z -> z
		z -> throw $ InternalError $ ("read_e error: for type " ++ (show $ typeOf y) ++ ": " ++ (show (x, z)))

mkuri page = fromJust $ parseURIReference page

getEnvironmentSetting name = lookup name <$> getEnvironment

getBaseDirectory filetype = do
	basedir <- addTrailingPathSeparator <$> do
		def <- getEnvironmentSetting "KOLPROXY_DIRECTORY"
		case def of
			Just x -> return x
			_ -> getAppUserDataDirectory "kolproxy"
	let dirpath = case filetype of
		"log" -> basedir ++ "logs/"
		"detailed log" -> basedir ++ "logs/detailed/"
		"sqlite3 log" -> basedir ++ "logs/raw/"
		"sqlite3 chatlog" -> basedir ++ "logs/chat/"
		"state" -> basedir ++ "state/"
		_ -> throw $ InternalError $ "Invalid directory path type: " ++ filetype
	createDirectoryIfMissing True dirpath
	return dirpath

getDirectoryPath filetype filepath = do
	basedir <- getBaseDirectory filetype
	return (basedir ++ filepath)

decodeUrlParams x = formDecode <$> stripPrefix "?" (uriQuery x)


cookie_to_sessid cookie =
	case cookie of
		Just x -> case matchGroups "PHPSESSID=([0-9a-z]+)" x of
			[[phpsessid]] -> Just $ get_md5 phpsessid
			_ -> Nothing
		_ -> Nothing

get_sessid ref = cookie_to_sessid $ cookie_ $ connection $ ref


canReadState ref = return $ stateValid_ ref :: IO Bool




create_db place filename = do
	path <- getDirectoryPath place filename
	db <- Database.SQLite3Modded.open path
	do_db_query_ db "PRAGMA fullfsync = 1;" []
	return db

do_db_query db query params = (do
	s <- Database.SQLite3Modded.prepare db query
	Database.SQLite3Modded.bind s $ map (\x -> case x of
		Nothing -> Database.SQLite3Modded.SQLNull
		Just t -> Database.SQLite3Modded.SQLText t) params
	let getresults acc = do
		sr <- Database.SQLite3Modded.step s
		case sr of
			Database.SQLite3Modded.Row -> do
				rawcs <- Database.SQLite3Modded.columns s
				let convertedcs = map (\x -> case x of
					Database.SQLite3Modded.SQLNull -> Nothing
					Database.SQLite3Modded.SQLText t -> Just t
					Database.SQLite3Modded.SQLInteger i -> Just $ Data.ByteString.Char8.pack $ show i
					_ -> throw $ InternalError $ "Unexpected database contents") rawcs
				getresults (acc ++ [convertedcs])
			Database.SQLite3Modded.Done -> return acc
	r <- getresults []
	Database.SQLite3Modded.finalize s
	return r) `catch` (\e -> do
		putStrLn $ "db exception: " ++ (show (e :: SomeException))
		putStrLn $ "  for query: " ++ query
		throwIO e)

do_db_query_ db query params = void $ do_db_query db query params

forkIO_ name x = void $ forkIO $ x `catch` (\e -> do
	putStrLn $ "WARNING: " ++ name ++ " exception: " ++ (show (e :: SomeException))
	return ())

get_custom_autoload_script_files = do
	filenames <- getDirectoryContents "scripts/custom-autoload"
	return $ filter (=~ "\\.lua$") filenames

debug_do msg x = (x) `catch` (\e -> do
	putStrLn $ "DEBUG: " ++ msg ++ " exception: " ++ show (e :: SomeException)
	throwIO e)
