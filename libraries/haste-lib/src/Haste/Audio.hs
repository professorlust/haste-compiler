{-# LANGUAGE OverloadedStrings #-}
-- | High-ish level bindings to the HTML5 audio tag and JS API.
module Haste.Audio (
    Audio, AudioSettings (..), AudioType (..), AudioSource (..),
    AudioPreload (..), AudioState (..), Seek (..),
    def,
    mkSource, newAudio, setSource,
    getState,
    setMute, isMute, toggleMute,
    setLooping, isLooping, toggleLooping,
    getVolume, setVolume, modVolume,
    play, pause, stop, togglePlaying,
    seek, getDuration
  ) where
import Haste
import Haste.DOM.JSString
import Haste.Foreign
import Control.Applicative
import Control.Monad
import Data.Default
import Data.String

-- | Represents an audio player.
data Audio = Audio Elem

instance IsElem Audio where
  elemOf (Audio e) = e
  fromElem e = do
    tn <- getProp e "tagName"
    return $ case tn of
      "AUDIO" -> Just $ Audio e
      "audio" -> Just $ Audio e
      _       -> Nothing

data AudioState = Playing | Paused | Ended
  deriving (Show, Eq)
data AudioType = MP3 | OGG | WAV
  deriving (Show, Eq)
data AudioSource = AudioSource !AudioType !JSString
  deriving (Show, Eq)
data AudioPreload = None | Metadata | Auto
  deriving Eq
data Seek = Start | End | Seconds Int
  deriving Eq

instance JSType AudioPreload where
  toJSString None     = "none"
  toJSString Metadata = "metadata"
  toJSString Auto     = "auto"
  fromJSString "none"     = Just None
  fromJSString "metadata" = Just Metadata
  fromJSString "auto"     = Just Auto
  fromJSString _          = Nothing

data AudioSettings = AudioSettings {
    -- | Show controls?
    --   Default: False
    audioControls :: !Bool,
    -- | Immediately start playing?
    --   Default: False
    audioAutoplay :: !Bool,
    -- | Initially looping?
    --   Default: False
    audioLoop     :: !Bool,
    -- | How much audio to preload.
    --   Default: Auto
    audioPreload  :: !AudioPreload,
    -- | Initially muted?
    --   Default: False
    audioMuted    :: !Bool,
    -- | Initial volume
    --   Default: 0
    audioVolume   :: !Double
  }

instance Default AudioSettings where
  def = AudioSettings {
      audioControls = False,
      audioAutoplay = False,
      audioLoop = False,
      audioPreload = Auto,
      audioMuted = False,
      audioVolume = 0
    }

-- | Create an audio source with automatically detected media type, based on
--   the given URL's file extension.
--   Returns Nothing if the given URL has an unrecognized media type.
mkSource :: JSString -> Maybe AudioSource
mkSource url =
  case take 3 $ reverse $ fromJSStr url of
    "3pm" -> Just $ AudioSource MP3 url
    "ggo" -> Just $ AudioSource OGG url
    "vaw" -> Just $ AudioSource WAV url
    _     -> Nothing

instance IsString AudioSource where
  fromString s =
    case mkSource $ Data.String.fromString s of
      Just src -> src
      _        -> error $ "Not a valid audio source: " ++ s

mimeStr :: AudioType -> JSString
mimeStr MP3 = "audio/mpeg"
mimeStr OGG = "audio/ogg"
mimeStr WAV = "audio/wav"

-- | Create a new audio element.
newAudio :: AudioSettings -> [AudioSource] -> IO Audio
newAudio cfg sources = do
  srcs <- forM sources $ \(AudioSource t url) -> do
    newElem "source" `with` ["type" =: mimeStr t, "src" =: toJSString url]
  Audio <$> newElem "audio" `with` [
      "controls" =: falseAsEmpty (audioControls cfg),
      "autoplay" =: falseAsEmpty (audioAutoplay cfg),
      "looping"  =: falseAsEmpty (audioLoop cfg),
      "muted"    =: falseAsEmpty (audioMuted cfg),
      "volume"   =: toJSString (audioVolume cfg),
      "preload"  =: toJSString (audioPreload cfg),
      children srcs
    ]

-- | Returns "true" or "", depending on the given boolean.
falseAsEmpty :: Bool -> JSString
falseAsEmpty True = "true"
falseAsEmpty _    = ""

-- | (Un)mute the given audio object.
setMute :: Audio -> Bool -> IO ()
setMute (Audio e) = setAttr e "muted" . falseAsEmpty

-- | Is the given audio object muted?
isMute :: Audio -> IO Bool
isMute (Audio e) = maybe False id . fromJSString <$> getProp e "muted"

-- | Mute/unmute.
toggleMute :: Audio -> IO ()
toggleMute a = isMute a >>= setMute a . not

-- | Set whether the given sound should loop upon completion or not.
setLooping :: Audio -> Bool -> IO ()
setLooping (Audio e) = setAttr e "loop" . falseAsEmpty

-- | Is the given audio object looping?
isLooping :: Audio -> IO Bool
isLooping (Audio e) = maybe False id . fromJSString <$> getProp e "looping"

-- | Toggle looping on/off.
toggleLooping :: Audio -> IO ()
toggleLooping a = isLooping a >>= setLooping a . not

-- | Starts playing audio from the given element.
play :: Audio -> IO ()
play a@(Audio e) = do
    st <- getState a
    when (st == Ended) $ seek a Start
    play' e
  where
    play' :: Elem -> IO ()
    play' = ffi "(function(x){x.play();})"

-- | Get the current state of the given audio object.
getState :: Audio -> IO AudioState
getState (Audio e) = do
  paused <- maybe False id . fromJSString <$> getProp e "paused"
  ended <- maybe False id . fromJSString <$> getProp e "ended"
  return $ case (paused, ended) of
    (True, _) -> Paused
    (_, True) -> Ended
    _         -> Playing

-- | Pause the given audio element.
pause :: Audio -> IO ()
pause (Audio e) = pause' e
  where
    pause' :: Elem -> IO ()
    pause' = ffi "(function(x){x.pause();})"

-- | If playing, stop. Otherwise, start playing.
togglePlaying :: Audio -> IO ()
togglePlaying a = do
  st <- getState a
  case st of
    Playing    -> pause a
    Ended      -> seek a Start >> play a
    Paused     -> play a

-- | Stop playing a track, and seek back to its beginning.
stop :: Audio -> IO ()
stop a = pause a >> seek a Start

-- | Get the volume for the given audio element as a value between 0 and 1.
getVolume :: Audio -> IO Double
getVolume (Audio e) = maybe 0 id . fromJSString <$> getProp e "volume"

-- | Set the volume for the given audio element. The value will be clamped to
--   [0, 1].
setVolume :: Audio -> Double -> IO ()
setVolume (Audio e) = setProp e "volume" . toJSString . clamp 0 1

-- | Modify the volume for the given audio element. The resulting volume will
--   be clamped to [0, 1].
modVolume :: Audio -> Double -> IO ()
modVolume a diff = getVolume a >>= setVolume a . (+ diff)

-- | Clamp a value to [lo, hi].
clamp :: Double -> Double -> Double -> Double
clamp lo hi = max lo . min hi

-- | Seek to the specified time.
seek :: Audio -> Seek -> IO ()
seek a@(Audio e) st = do
    case st of
      Start     -> seek' e 0
      End       -> getDuration a >>= seek' e
      Seconds s -> seek' e s
  where
    seek' :: Elem -> Int -> IO ()
    seek' = ffi "(function(e,t) {e.currentTime = t;})"

-- | Get the duration of the loaded sound, in seconds.
getDuration :: Audio -> IO Int
getDuration (Audio e) = do
  dur <- getProp e "duration"
  case fromJSString dur of
    Just d -> return d
    _      -> return 0

-- | Set the source of the given audio element.
setSource :: Audio -> AudioSource -> IO ()
setSource (Audio e) (AudioSource _ url) = setProp e "src" (toJSString url)
