{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
-- | A file browser widget that allows users to navigate directory
-- trees, search for files and directories, and select a file of
-- interest.
--
-- To use, embed a 'FileBrowser' in your application state. Dispatch
-- events to it in your event handler with 'handleFileBrowserEvent'.
-- Get the entry under the browser's cursor with 'fileBrowserCursor'
-- and get the entry selected by the user with 'Enter' using
-- 'fileBrowserSelection'. See the documentation below for handled
-- events.
--
-- File browsers have a built-in user-configurable function to limit the
-- entries displayed. For example, an application might want to limit
-- the browser to just directories and XML files. That is accomplished
-- by setting the filter with 'setFileBrowserEntryFilter'.
--
-- File browsers are styled using the provided collection of attribute
-- names, so add those to your attribute map to get the appearance you
-- want. File browsers also make use of a 'List' internally, so the
-- 'List' attributes will affect how the list appears.
module Brick.Widgets.FileBrowser
  ( -- * The FileBrowser and related types
    FileBrowser
  , FileInfo(..)
  , FileType(..)
  -- * Making a new file browser
  , newFileBrowser

  -- * Manipulating a file browser's state
  , setWorkingDirectory
  , getWorkingDirectory
  , updateFileBrowserSearch
  , setFileBrowserEntryFilter

  -- * Handling events
  , handleFileBrowserEvent

  -- * Rendering
  , renderFileBrowser

  -- * Getting information
  , fileBrowserCursor
  , fileBrowserIsSearching
  , fileBrowserSelection

  -- * Attributes
  , fileBrowserAttr
  , fileBrowserCurrentDirectoryAttr
  , fileBrowserSelectionInfoAttr
  , fileBrowserDirectoryAttr
  , fileBrowserBlockDeviceAttr
  , fileBrowserRegularFileAttr
  , fileBrowserCharacterDeviceAttr
  , fileBrowserNamedPipeAttr
  , fileBrowserSymbolicLinkAttr
  , fileBrowserSocketAttr

  -- * File type filters
  , fileTypeMatch
  , fileExtensionMatch

  -- * Miscellaneous
  , prettyFileSize

  -- * Lenses
  , fileBrowserEntryFilterL
  , fileInfoFilenameL
  , fileInfoFileSizeL
  , fileInfoSanitizedFilenameL
  , fileInfoFilePathL
  , fileInfoFileTypeL

  )
where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toLower, isPrint)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
#if !(MIN_VERSION_base(4,11,0))
import Data.Monoid
#endif
import Data.Int (Int64)
import Data.List (sortBy, isSuffixOf)
import qualified Data.Vector as V
import Lens.Micro
import qualified Graphics.Vty as Vty
import qualified System.Directory as D
import qualified System.Posix.Files as U
import qualified System.Posix.Types as U
import qualified System.FilePath as FP
import Text.Printf (printf)

import Brick.Types
import Brick.AttrMap (AttrName)
import Brick.Widgets.Core
import Brick.Widgets.List

-- | A file browser's state. Embed this in your application state and
-- transform it with 'handleFileBrowserEvent' and the functions included
-- in this module.
data FileBrowser n =
    FileBrowser { fileBrowserWorkingDirectory :: FilePath
                , fileBrowserEntries :: List n FileInfo
                , fileBrowserLatestResults :: [FileInfo]
                , fileBrowserName :: n
                , fileBrowserSelectionState :: Maybe FileInfo
                , fileBrowserEntryFilter :: Maybe (FileInfo -> Bool)
                , fileBrowserSearchString :: Maybe T.Text
                }

-- | Information about a file entry in the browser.
data FileInfo =
    FileInfo { fileInfoFilename :: String
             -- ^ The filename of this entry, without its path.
             -- This is not for display purposes; for that, use
             -- 'fileInfoSanitizedFilename'.
             , fileInfoSanitizedFilename :: String
             -- ^ The filename of this entry with out its path,
             -- sanitized of non-printable characters (replaced with
             -- '?'). This is for display purposes only.
             , fileInfoFilePath :: FilePath
             -- ^ The full path to this entry's file.
             , fileInfoFileType :: Maybe FileType
             -- ^ The type of this entry's file, if it could be
             -- determined.
             , fileInfoFileSize :: Int64
             -- ^ The size, in bytes, of this entry's file.
             }
             deriving (Show, Eq, Read)

-- | The type of file entries in the browser.
data FileType =
    RegularFile
    -- ^ A regular disk file.
    | BlockDevice
    -- ^ A block device.
    | CharacterDevice
    -- ^ A character device.
    | NamedPipe
    -- ^ A named pipe.
    | Directory
    -- ^ A directory.
    | SymbolicLink
    -- ^ A symbolic link.
    | Socket
    -- ^ A Unix socket.
    deriving (Read, Show, Eq)

suffixLenses ''FileBrowser
suffixLenses ''FileInfo

-- | Make a new file browser state. The provided resource name will be
-- used to render the 'List' viewport of the browser.
newFileBrowser :: n
               -- ^ The resource name associated with the browser's
               -- entry listing.
               -> Maybe FilePath
               -- ^ The initial working directory that the browser
               -- displays. If not provided, this defaults to the
               -- executable's current working directory.
               -> IO (FileBrowser n)
newFileBrowser name mCwd = do
    initialCwd <- case mCwd of
        Just path -> return path
        Nothing -> D.getCurrentDirectory

    let b = FileBrowser { fileBrowserWorkingDirectory = initialCwd
                        , fileBrowserEntries = list name mempty 1
                        , fileBrowserLatestResults = mempty
                        , fileBrowserName = name
                        , fileBrowserSelectionState = Nothing
                        , fileBrowserEntryFilter = Nothing
                        , fileBrowserSearchString = Nothing
                        }

    setWorkingDirectory initialCwd b

-- | Set the filtering function used to determine which entries in the
-- browser's current directory appear in the browser.
setFileBrowserEntryFilter :: Maybe (FileInfo -> Bool) -> FileBrowser n -> FileBrowser n
setFileBrowserEntryFilter f b =
    applyFilterAndSearch $ b & fileBrowserEntryFilterL .~ f

-- | Set the working directory of the file browser. This scans the new
-- directory and repopulates the browser while maintaining any active
-- search string and/or entry filtering.
setWorkingDirectory :: FilePath -> FileBrowser n -> IO (FileBrowser n)
setWorkingDirectory path b = do
    entries <- entriesForDirectory path
    let b' = setEntries entries b
    return $ b' & fileBrowserWorkingDirectoryL .~ path

-- | Get the working directory of the file browser.
getWorkingDirectory :: FileBrowser n -> FilePath
getWorkingDirectory = fileBrowserWorkingDirectory

setEntries :: [FileInfo] -> FileBrowser n -> FileBrowser n
setEntries es b =
    applyFilterAndSearch $ b & fileBrowserLatestResultsL .~ es

-- | Returns whether the file browser is in search mode, i.e., the mode
-- in which user input affects the browser's active search string and
-- displayed entries. This is used to aid in event dispatching in the
-- calling program.
fileBrowserIsSearching :: FileBrowser n -> Bool
fileBrowserIsSearching b = isJust $ b^.fileBrowserSearchStringL

-- | Get the entry chosen by the user, if any. The entry is chosen
-- by an 'Enter' keypress; if you want the entry under the cursor, use
-- 'fileBrowserCursor'.
fileBrowserSelection :: FileBrowser n -> Maybe FileInfo
fileBrowserSelection = fileBrowserSelectionState

-- | Modify the file browser's active search string. This causes the
-- browser's displayed entries to change to those in its current
-- directory that match the search string, if any. If a search string
-- is provided, it is matched case-insensitively anywhere in file or
-- directory names.
updateFileBrowserSearch :: (Maybe T.Text -> Maybe T.Text)
                        -- ^ The search transformation. 'Nothing'
                        -- indicates that search mode should be off;
                        -- 'Just' indicates that it should be on and
                        -- that the provided search string should be
                        -- used.
                        -> FileBrowser n
                        -- ^ The browser to modify.
                        -> FileBrowser n
updateFileBrowserSearch f b =
    let old = b^.fileBrowserSearchStringL
        new = f $ b^.fileBrowserSearchStringL
        oldLen = maybe 0 T.length old
        newLen = maybe 0 T.length new
    in if old == new
       then b
       else if oldLen == newLen
            -- This case avoids a list rebuild and cursor position reset
            -- when the search state isn't *really* changing.
            then b & fileBrowserSearchStringL .~ new
            else applyFilterAndSearch $ b & fileBrowserSearchStringL .~ new

applyFilterAndSearch :: FileBrowser n -> FileBrowser n
applyFilterAndSearch b =
    let filterMatch = fromMaybe (const True) (b^.fileBrowserEntryFilterL)
        searchMatch = maybe (const True)
                            (\search i -> (T.toLower search `T.isInfixOf` (T.pack $ toLower <$> fileInfoSanitizedFilename i)))
                            (b^.fileBrowserSearchStringL)
        match i = filterMatch i && searchMatch i
        matching = filter match $ b^.fileBrowserLatestResultsL
    in b { fileBrowserEntries = list (b^.fileBrowserNameL) (V.fromList matching) 1 }

-- | Generate a textual abbreviation of a file size, e.g. "10.2M" or "12
-- bytes".
prettyFileSize :: Int64
               -- ^ A file size in bytes.
               -> T.Text
prettyFileSize i
    | i >= 2 ^ (40::Int64) = T.pack $ format (i `divBy` (2 ** 40)) <> "T"
    | i >= 2 ^ (30::Int64) = T.pack $ format (i `divBy` (2 ** 30)) <> "G"
    | i >= 2 ^ (20::Int64) = T.pack $ format (i `divBy` (2 ** 20)) <> "M"
    | i >= 2 ^ (10::Int64) = T.pack $ format (i `divBy` (2 ** 10)) <> "K"
    | otherwise    = T.pack $ show i <> " bytes"
    where
        format = printf "%0.1f"
        divBy :: Int64 -> Double -> Double
        divBy a b = ((fromIntegral a) :: Double) / b

entriesForDirectory :: FilePath -> IO [FileInfo]
entriesForDirectory rawPath = do
    path <- D.makeAbsolute rawPath

    -- Get all entries except "." and "..", then sort them
    dirContents <- D.listDirectory path

    let addParent = if path == "/"
                    then id
                    else (parentDir :)
        parentDir = ".."
        allFiles = addParent dirContents

    infos <- forM allFiles $ \f -> do
        filePath <- D.canonicalizePath $ path FP.</> f
        status <- U.getFileStatus filePath
        let U.COff sz = U.fileSize status
        return FileInfo { fileInfoFilename = f
                        , fileInfoFilePath = filePath
                        , fileInfoSanitizedFilename = sanitizeFilename f
                        , fileInfoFileType = fileTypeFromStatus status
                        , fileInfoFileSize = sz
                        }

    let dirsFirst a b = if fileInfoFileType a == Just Directory &&
                           fileInfoFileType b == Just Directory
                        then compare (toLower <$> fileInfoFilename a)
                                     (toLower <$> fileInfoFilename b)
                        else if fileInfoFileType a == Just Directory &&
                                fileInfoFileType b /= Just Directory
                             then LT
                             else if fileInfoFileType b == Just Directory &&
                                     fileInfoFileType a /= Just Directory
                                  then GT
                                  else compare (toLower <$> fileInfoFilename a)
                                               (toLower <$> fileInfoFilename b)

        allEntries = sortBy dirsFirst infos

    return allEntries

fileTypeFromStatus :: U.FileStatus -> Maybe FileType
fileTypeFromStatus s =
    if | U.isBlockDevice s     -> Just BlockDevice
       | U.isCharacterDevice s -> Just CharacterDevice
       | U.isNamedPipe s       -> Just NamedPipe
       | U.isRegularFile s     -> Just RegularFile
       | U.isDirectory s       -> Just Directory
       | U.isSocket s          -> Just Socket
       | U.isSymbolicLink s    -> Just SymbolicLink
       | otherwise             -> Nothing

-- | Get the file information for the file under the cursor, if any.
fileBrowserCursor :: FileBrowser n -> Maybe FileInfo
fileBrowserCursor b = snd <$> listSelectedElement (b^.fileBrowserEntriesL)

-- | Handle a Vty input event.
--
-- Events handled in normal mode:
--
-- * @Enter@: set the file browser's selected entry
--   ('fileBrowserSelection') for use by the calling application
-- * @/@: enter search mode
--
-- Events handled in search mode:
--
-- * @Esc@, @Ctrl-C@: cancel search mode
-- * @Enter@: set the file browser's selected entry
--   ('fileBrowserSelection') for use by the calling application
-- * Other input: update search string
handleFileBrowserEvent :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEvent e b =
    if fileBrowserIsSearching b
    then handleFileBrowserEventSearching e b
    else handleFileBrowserEventNormal e b

safeInit :: T.Text -> T.Text
safeInit t | T.length t == 0 = t
           | otherwise = T.init t

handleFileBrowserEventSearching :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEventSearching e b =
    case e of
        Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl] ->
            return $ updateFileBrowserSearch (const Nothing) b
        Vty.EvKey Vty.KEsc [] ->
            return $ updateFileBrowserSearch (const Nothing) b
        Vty.EvKey Vty.KBS [] ->
            return $ updateFileBrowserSearch (fmap safeInit) b
        Vty.EvKey Vty.KEnter [] ->
            maybeSelectCurrentEntry b
        Vty.EvKey (Vty.KChar c) [] ->
            return $ updateFileBrowserSearch (fmap (flip T.snoc c)) b
        _ ->
            handleEventLensed b fileBrowserEntriesL handleListEvent e

handleFileBrowserEventNormal :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEventNormal e b =
    case e of
        Vty.EvKey (Vty.KChar '/') [] ->
            -- Begin file search
            return $ updateFileBrowserSearch (const $ Just "") b
        Vty.EvKey Vty.KEnter [] ->
            -- Select file or enter directory
            maybeSelectCurrentEntry b
        _ ->
            -- Otherwise, delegate event to entry list
            handleEventLensed b fileBrowserEntriesL handleListEvent e

maybeSelectCurrentEntry :: FileBrowser n -> EventM n (FileBrowser n)
maybeSelectCurrentEntry b =
    case fileBrowserCursor b of
        Nothing -> return b
        Just entry ->
            case fileInfoFileType entry of
                Just Directory -> liftIO $ setWorkingDirectory (fileInfoFilePath entry) b
                _ -> return $ b & fileBrowserSelectionStateL .~ Just entry

-- | Render a file browser.
--
-- The file browser is greedy in both dimensions.
renderFileBrowser :: (Show n, Ord n)
                  => Bool
                  -- ^ Whether the file browser has input focus.
                  -> FileBrowser n
                  -- ^ The browser to render.
                  -> Widget n
renderFileBrowser foc b =
    let maxFilenameLength = maximum $ (length . fileInfoFilename) <$> (b^.fileBrowserEntriesL)
        cwdHeader = padRight Max $
                    str $ sanitizeFilename $ fileBrowserWorkingDirectory b
        selInfo = case listSelectedElement (b^.fileBrowserEntriesL) of
            Nothing -> vLimit 1 $ fill ' '
            Just (_, i) -> padRight Max $ selInfoFor i
        fileTypeLabel Nothing = "unknown"
        fileTypeLabel (Just t) =
            case t of
                RegularFile -> "file"
                BlockDevice -> "block device"
                CharacterDevice -> "character device"
                NamedPipe -> "pipe"
                Directory -> "directory"
                SymbolicLink -> "symbolic link"
                Socket -> "socket"
        selInfoFor i =
            let maybeSize = if fileInfoFileType i == Just RegularFile
                            then ", " <> prettyFileSize (fileInfoFileSize i)
                            else ""
            in txt $ (T.pack $ fileInfoSanitizedFilename i) <> ": " <>
                     fileTypeLabel (fileInfoFileType i) <> maybeSize
        maybeSearchInfo = case b^.fileBrowserSearchStringL of
            Nothing -> emptyWidget
            Just s -> padRight Max $
                      txt "Search: " <+>
                      showCursor (b^.fileBrowserNameL) (Location (T.length s, 0)) (txt s)

    in withDefAttr fileBrowserAttr $
       vBox [ withDefAttr fileBrowserCurrentDirectoryAttr cwdHeader
            , renderList (renderFileInfo foc maxFilenameLength) foc (b^.fileBrowserEntriesL)
            , maybeSearchInfo
            , withDefAttr fileBrowserSelectionInfoAttr selInfo
            ]

renderFileInfo :: Bool -> Int -> Bool -> FileInfo -> Widget n
renderFileInfo foc maxLen sel info =
    (if foc
     then (if sel then forceAttr listSelectedFocusedAttr else id)
     else (if sel then forceAttr listSelectedAttr else id)) $
    padRight Max body
    where
        addAttr = maybe id (withDefAttr . attrForFileType) (fileInfoFileType info)
        body = addAttr (hLimit (maxLen + 1) $ padRight Max $ str $ fileInfoSanitizedFilename info <> suffix)
        suffix = if fileInfoFileType info == Just Directory
                 then "/"
                 else ""

-- | Sanitize a filename for terminal display, replacing non-printable
-- characters with '?'.
sanitizeFilename :: String -> String
sanitizeFilename = fmap toPrint
    where
        toPrint c | isPrint c = c
                  | otherwise = '?'

attrForFileType :: FileType -> AttrName
attrForFileType RegularFile = fileBrowserRegularFileAttr
attrForFileType BlockDevice = fileBrowserBlockDeviceAttr
attrForFileType CharacterDevice = fileBrowserCharacterDeviceAttr
attrForFileType NamedPipe = fileBrowserNamedPipeAttr
attrForFileType Directory = fileBrowserDirectoryAttr
attrForFileType SymbolicLink = fileBrowserSymbolicLinkAttr
attrForFileType Socket = fileBrowserSocketAttr

fileBrowserAttr :: AttrName
fileBrowserAttr = "fileBrowser"

fileBrowserCurrentDirectoryAttr :: AttrName
fileBrowserCurrentDirectoryAttr = fileBrowserAttr <> "currentDirectory"

fileBrowserSelectionInfoAttr :: AttrName
fileBrowserSelectionInfoAttr = fileBrowserAttr <> "selectionInfo"

fileBrowserDirectoryAttr :: AttrName
fileBrowserDirectoryAttr = fileBrowserAttr <> "directory"

fileBrowserBlockDeviceAttr :: AttrName
fileBrowserBlockDeviceAttr = fileBrowserAttr <> "block"

fileBrowserRegularFileAttr :: AttrName
fileBrowserRegularFileAttr = fileBrowserAttr <> "regular"

fileBrowserCharacterDeviceAttr :: AttrName
fileBrowserCharacterDeviceAttr = fileBrowserAttr <> "char"

fileBrowserNamedPipeAttr :: AttrName
fileBrowserNamedPipeAttr = fileBrowserAttr <> "pipe"

fileBrowserSymbolicLinkAttr :: AttrName
fileBrowserSymbolicLinkAttr = fileBrowserAttr <> "symlink"

fileBrowserSocketAttr :: AttrName
fileBrowserSocketAttr = fileBrowserAttr <> "socket"

-- | A file type filter for use with 'setFileBrowserEntryFilter'. This
-- filter permits entries whose file types are in the specified list.
fileTypeMatch :: [FileType] -> FileInfo -> Bool
fileTypeMatch tys i = maybe False (`elem` tys) $ fileInfoFileType i

-- | A filter that matches any directory regardless of name, or any
-- regular file with the specified extension. For example, an extension
-- argument of @"xml"@ would match regular files @test.xml@ and
-- @TEST.XML@ and it will match directories regardless of name.
fileExtensionMatch :: String -> FileInfo -> Bool
fileExtensionMatch ext i =
    ('.' : (toLower <$> ext)) `isSuffixOf` (toLower <$> fileInfoFilename i)