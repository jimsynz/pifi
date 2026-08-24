# Plan: the playback controls

- Date: 2026-08-24
- Status: done. 690 tests pass, `mix check` is green, and a read on the board on
  2026-08-24 gave controls that behave.
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

The player accepts `play`, `stop`, `standby` and `output`. A person who listens to a
podcast episode therefore holds two controls: play it from the place that it holds,
or stop it. There is no pause, no way to move to another episode, and no way to move
inside one.

A stereo component holds those controls, and section 3 of `docs/spec.md` names this
firmware a stereo component. This plan adds them.

Section 9 of the specification says "No interface holds a control that moves through
a stream". That sentence describes the firmware of 2026-08-23, and this plan removes
it.

## 2. Decisions

| Question | Decision |
|---|---|
| How does a pause work? | It stops the pipeline, it keeps the track selected, and it writes the place. A play starts the pipeline at that place. |
| What do next and previous mean? | The source decides. `MyHiFi.Source` holds two new callbacks. |
| How far does a skip reach? | A number of milliseconds from the current point, forward or backward. There is no jump to a named point, and no scrub bar. |
| How far do the controls of the web interface move? | Back 15 seconds, and forward 30 seconds. |
| Does a skip start the pipeline again? | No. `MyHiFi.Player.FileSource` moves the byte that it reads, and the pipeline continues. |
| How does a skip find the byte of a time? | It walks the MP3 frame headers of the file and it adds the length of each frame. |
| Which formats hold a skip? | MP3 alone. 8771 of the 8773 episodes of the measurement hold `audio/mpeg`. See section 4.4. |
| Does a live stream hold a skip? | No. A live stream has no place. |
| Does a live stream hold a pause? | Yes. It stops the audio and it keeps the station selected. A play opens the station again, at the current point of the stream. |
| How does a user interface know which controls to draw? | It asks the source. `MyHiFi.Source.capabilities/0` gives the list, and a control that is not in the list is disabled. |

## 3. What each control does

| Control | A live station | A podcast episode |
|---|---|---|
| Play, after a pause | Opens the station again | Starts at the place that it holds |
| Pause | Stops the audio, keeps the station | Stops the audio, writes the place |
| Next | The next favourite station | The next episode of the same show |
| Previous | The favourite station before | The episode before, of the same show |
| Skip forward | `{:error, :cannot_skip}` | Moves the reader forward |
| Skip backward | `{:error, :cannot_skip}` | Moves the reader backward |
| Stop | Clears the station | Writes the place and clears the episode |

Stop stays as it is. Pause and stop are not the same control: a stop leaves the
device with nothing selected, and a pause leaves the track in front of the person.

### 3.1 The order of next and previous

A source gives the order, and the order is the one that a person sees in the browse
list.

- **Podcasts.** `episodes_of_show/1` sorts by `published_at` in descending order, so
  the newest episode is at the top. Next moves down that list, to the episode before
  in time. The list ends, and the last episode gives `{:error, :no_more}`.
- **Internet radio.** `favourite_stations/0` gives the list, and the presets of a
  stereo have no end, so this list moves round. A station that is not a favourite
  gives the first favourite for next, and the last one for previous. No favourite at
  all gives `{:error, :no_more}`.

## 4. The skip

### 4.1 Why the reader moves, and the pipeline does not stop

A pause stops the pipeline, because a pause makes no sound and the place is on the
disk. A skip must keep playing, and three facts make a stop the wrong answer for it.

1. `MyHiFi.Output.APlaySink` starts `aplay` again for each pipeline, and `aplay`
   opens the sound card. The card is the part of this board that fails, and a skip
   is a control that a person presses again and again.
2. A start reads `buffer_bytes` before the first sound, so each skip would hold a
   silence of about one second.
3. `MyHiFi.Player.FileSource` already holds the open file, and it is already the
   watcher of the download.

The player therefore calls the pipeline, the pipeline notifies the source child, and
the element moves `state.offset`. `:file.pread/3` reads the new place on the next
demand.

The buffers that already left the element still play: the queue of the decoder holds
about 16 KB, which is one second of a 128 kbit/s episode, and the queue of the port
holds 128 KB of samples, which is half a second. A person therefore hears the old
audio for about one and a half seconds after a skip. The display moves at once,
because the player holds the count.

### 4.2 Why it walks the frames

**A bitrate cannot turn a time into a byte.** 11 of the 46 episodes of the
measurement of 2026-08-24 hold more than one bitrate, and a resume that used one
landed as much as 1994.6 s from the mark. Section 17 of the specification holds that
measurement, and it is the reason that `MyHiFi.Player.FileSource` reads a byte and
not a time.

An MP3 frame header holds the bitrate and the sample rate of that frame, so it gives
the length of the frame in bytes and its length in time. A walk forward therefore
measures a real span of time, and it holds for a file of one bitrate and for a file
of many. `MyHiFi.Player.Mp3Frame` already walks forward, and it already confirms a
frame with the frame that follows it.

### 4.3 Forward, and backward

**Forward is a walk.** It begins at a confirmed frame at the current point, and it
adds the length of each frame until the sum reaches the number of milliseconds that
the person asked for. It reads what it walks over, which is 30 seconds of audio for
the control of the web interface, or about 480 KB at 128 kbit/s.

**Backward is a measurement, and not an estimate.** A frame holds no pointer to the
frame before it, so nothing walks backward. The element therefore:

1. reads the header at the current point, which gives the bitrate of the audio here;
2. multiplies that bitrate by the time to find a candidate byte;
3. walks forward from the candidate to the current point, which measures the real
   time between the two;
4. moves the candidate one time if the measurement is more than a fifth away from
   the request, and measures again.

The number that the player then holds is the measured one, so the display and the
place stay correct. A file of one bitrate lands exactly. A file of many lands near,
and it names where it landed.

### 4.4 What it does not hold

- **A format other than MP3** gives `{:error, :cannot_skip}`. `MyHiFi.Player.Mp3Frame`
  reads MP3 frames, and an ADTS frame needs another parser. 8771 of the 8773 episodes
  of the measurement hold `audio/mpeg`, and 2 hold `audio/x-m4a`, which this firmware
  cannot play at all. A parser for a format that no episode holds is work with no
  reader.
- **A skip while paused.** No pipeline runs, so there is nothing to move. The control
  needs a play first.
- **A skip past the end of the file.** It moves to the end. A whole file then ends the
  stream, and the source marks the episode played, in the way that section 5.6.1
  describes.
- **A skip past the point that the download reached.** It moves to that point. The
  element then waits for the bytes, which is what it already does when the network is
  slower than the audio.

## 5. The interfaces

### 5.1 `MyHiFi.Player`

Four functions join the ones that are there.

```elixir
@spec pause(boolean()) :: :ok | {:error, term()}
@spec next() :: :ok | {:error, term()}
@spec previous() :: :ok | {:error, term()}
@spec skip(integer()) :: :ok | {:error, term()}
```

`pause/1` takes a boolean, in the way that `standby/1` does, so nothing needs to
read the state to make the call. `skip/1` takes one signed number, so a backward
skip is a negative one and there is one function and one action for both directions.

`state/0` gives one more field, `paused?`.

The state struct holds `paused?`. It becomes true when a person pauses, and it
becomes true when the firmware restores the last track at a start. A boot therefore
shows a track and a play control, which is what section 9 asks for: the device
selects the station and plays nothing.

`play/2`, `stop/0`, `next/0` and `previous/0` each set it to false.

Standby is the state of the device, and pause is the state of a track. A standby
that a person leaves starts the track again, unless the track is paused. A paused
track then stays paused, because a person who paused a track and then pressed
standby did not ask for music.

### 5.2 `MyHiFi.Playback`

One action for each function: `pause` with the argument `paused?`, `next`,
`previous`, and `skip` with the argument `ms`. `@state_fields` holds `paused?`.

### 5.3 `MyHiFi.Source`

```elixir
@type capability :: :next | :previous | :search | :skip

@callback capabilities() :: [capability()]
@callback next(ref()) :: {:ok, ref()} | {:error, term()}
@callback previous(ref()) :: {:ok, ref()} | {:error, term()}
```

A source that holds no order gives `{:error, :not_supported}`, in the way that
`search/2` and `favourite/2` do. The end of a list gives `{:error, :no_more}`, and
the two are different: a user interface can draw no control at all for the first
one.

Both sources of this firmware implement both callbacks. See section 3.1.

#### The capabilities

A radio station holds no place, so nothing can move through it. A user interface
must therefore know that before it draws a control, and the answer belongs to the
source and not to the interface.

- `MyHiFi.Source.InternetRadio` gives `[:next, :previous, :search]`.
- `MyHiFi.Source.Podcasts` gives `[:next, :previous, :search, :skip]`.

The player asks as well. A skip of a source with no `:skip` gives
`{:error, :cannot_skip}` and it reaches no pipeline, and next and previous give
`{:error, :not_supported}` in the same way. The list is therefore one fact that
each part reads, and not a copy in each user interface.

**`:search` is in the list, and `:favourite` is not.** `MyHiFiWeb.BrowseLive` calls
`search/2` today, it reads `{:error, :not_supported}`, and it holds the answer in its
own state, because the behaviour gives no way to ask in advance. This callback is
that way, so the page reads the list instead and it needs no memory and no error. A
favourite stays where it is: each entry carries `favourite?`, and that is the more
exact answer, because internet radio marks a track and podcasts mark a container.

`capabilities/0` names what a source holds, and not what one track holds. The player
still refuses a skip of a track that holds no place: a live stream gives
`{:error, :cannot_skip}`, and so does a format that
`MyHiFi.Player.Mp3Frame` cannot read. See section 4.4.

### 5.4 `MyHiFi.Event.Player`

- **`Paused`** is new. It holds `position_ms`. The audio stopped and the track stays
  selected, so a user interface keeps the title and it draws a play control.
- **`Started`** holds one new field, `position_ms`. A resume of an episode begins in
  the middle, and `MyHiFi.Event.Player.Progress` arrives one second later.
  `MyHiFiWeb.PlayerLive` sets the position to 0 at a start today, so a person reads
  00:00 for one second on each resume.

A skip publishes `Progress`, and it publishes it as soon as the element reports the
move. Nothing new is needed for it.

### 5.5 The web interface

The compact faceplate holds four controls and no more: standby, play or pause, stop,
and the display between them. A row of seven controls does not fit the screen of a
telephone.

The large view holds the whole transport row: previous, back 15 seconds, play or
pause, forward 30 seconds, next. Each one is a `round_control`, so the row needs no
new component.

A control that the source does not hold is disabled. `MyHiFiWeb.PlayerLive` reads
`capabilities/0` of the source that plays: the state gives that module at a mount,
and `MyHiFi.Event.Player.Started` gives it at each start. A radio station therefore
shows the two skip controls disabled, and it shows next and previous as controls
that move through the favourites.

## 6. The messages inside the pipeline

`MyHiFi.Player.Pipeline` gains one call and one notification, in the shape that
`:silence` and `{:position_bytes, bytes}` already hold.

```
Player                  Pipeline                     FileSource
  |  call {:skip, ms}       |                              |
  |----------------------->|  notify_child {:skip, ms}     |
  |         :ok            |----------------------------->|
  |<-----------------------|                              | walks the frames
  |                        | notify_parent                 |
  |                        |  {:skipped, %{byte:, ms:}}    |
  |  {:pipeline_skipped,   |<-----------------------------|
  |   pipeline, place}     |                              |
  |<-----------------------|                              |
```

The call answers before the walk, so the player never waits on a read of the disk. The
place holds both numbers, because the player holds both: it adds the measured
milliseconds to `offset_ms`, it takes the byte as the place of the reader, and it
publishes `Progress`. The byte matters as much as the time, because the player writes
it through `store_position/2` when a person stops.

An element that holds no skip, such as `MyHiFi.Player.HttpSource`, receives no
notification: the player refuses a skip of a live stream before it calls.

## 7. The files

| File | Change |
|---|---|
| `lib/my_hi_fi/player/mp3_frame.ex` | Two new functions: a walk forward of a number of milliseconds, and a measurement of the time between two bytes. |
| `lib/my_hi_fi/player/skip.ex` | New. It holds the estimate, the measurement, and the clamp of section 4.3. |
| `lib/my_hi_fi/player/file_source.ex` | It receives `{:skip, ms}`, it moves `state.offset`, and it reports the move. |
| `lib/my_hi_fi/player/pipeline.ex` | It carries the call and the notification. |
| `lib/my_hi_fi/player.ex` | `pause/1`, `next/0`, `previous/0`, `skip/1`, and `paused?` in the state. |
| `lib/my_hi_fi/playback.ex` | Four new actions. |
| `lib/my_hi_fi/playback/player.ex` | The actions, and `paused?` in `@state_fields`. |
| `lib/my_hi_fi/source.ex` | `capabilities/0`, `next/1` and `previous/1`. |
| `lib/my_hi_fi/source/internet_radio.ex` | The capabilities, and the favourites, which move round. |
| `lib/my_hi_fi/source/podcasts.ex` | The capabilities, and the episodes of the show, whose list ends. |
| `lib/my_hi_fi/event/player.ex` | `Paused`, and `position_ms` on `Started`. |
| `lib/my_hi_fi_web/live/player_live.ex` | The controls, and the events that they send. |
| `lib/my_hi_fi_web/live/browse_live.ex` | It reads `capabilities/0` for the search field, and it loses the branch that asks and remembers. |
| `docs/spec.md` | Sections 5.1, 5.5, 5.6, 9 and 10. |

## 8. Risks and unknowns

- **A skip makes the decoder meet a stream that jumps.** `Membrane.MP3.MAD.Decoder`
  skips bytes until it finds a frame, and the measurement of 2026-08-24 gave 591
  skips after a resume, which is under two frames. A skip lands on a frame boundary,
  so this cost is the same or less. The read on the board on 2026-08-24 heard nothing
  of it.
- **The walk reads the disk in the process of the element.** 480 KB of a card that
  gives about 20 MB each second is about 25 ms, and the element holds a lead of one
  and a half seconds over the sound. A slower card is a risk, and the read on the
  board must hold a skip that a person presses several times fast.
- **A file that the download has not reached.** The element must not read past
  `state.available`, and a walk that meets that limit must clamp and not fail.
- **The next episode of a show may hold no audio that this firmware plays.** An m4a
  episode gives `{:unsupported_format, …}` from `resolve/1`. Next then publishes
  `Failed` and the track stays where it was. This is what a play of that episode
  already does, so it needs no new path.
- **A test needs a pipeline that answers a skip.** `MyHiFi.Test.EndingPipeline` holds
  no element, so a test of the player and a skip needs another one of these, and the
  walk itself needs a test of its own with the frames that
  `MyHiFi.Player.Mp3FrameTest` builds.

## 9. Order of work

1. `MyHiFi.Player.Mp3Frame`: the walk forward, and the measurement between two
   bytes. Tests with the synthetic frames that the test module already builds, and a
   test of a file of two bitrates.
2. `MyHiFi.Player.Skip`: the estimate, the refinement, and the clamp. Tests of a
   forward skip, a backward skip, a skip past the end, and a file of two bitrates.
3. `MyHiFi.Player.FileSource`: `{:skip, ms}`, and the report of the move.
4. `MyHiFi.Player.Pipeline`: the call and the notification.
5. `MyHiFi.Event.Player`: `Paused`, and `position_ms` on `Started`.
6. `MyHiFi.Source`: `capabilities/0` and the two callbacks, and both sources.
7. `MyHiFi.Player`: `pause/1`, `next/0`, `previous/0`, `skip/1`, and `paused?`.
8. `MyHiFi.Playback`: the four actions.
9. `MyHiFiWeb.PlayerLive`: the controls. `MyHiFiWeb.BrowseLive`: the search field
   from the capabilities.
10. `docs/spec.md`, and `mix check`.
11. A read on the board: pause and play an episode, skip in both directions, and
    move to the next episode and to the next station. A read on 2026-08-24 did this,
    and it found nothing to change.

## 11. What the work found

Three faults that this plan did not hold.

- **A second candidate of a backward skip reaches past the start of the file.** The
  first measurement of a file of two bitrates landed at half of the request, so the
  scale of the second candidate gave a negative byte and `:file.pread/3` refused it.
  `MyHiFi.Player.Skip` holds the candidate at the start now. A test of the second
  measurement found this.
- **The tolerance of a fifth was too wide.** A file whose bitrate falls by half in the
  middle landed 2.6 s from a request of 30 s and the measurement stopped there. The
  second measurement reads bytes that the first one read, so the operating system holds
  those pages and the tolerance is a tenth now.
- **A pending restart of a lost stream reached a player that played something else.**
  `MyHiFi.Player` scheduled `:restart` two seconds out and cancelled it nowhere, so a
  person who changed station inside those two seconds met a second pipeline beside the
  one that played, and the second `aplay` finds the sound card busy. The player holds
  the reference of that timer now, and a start and a stop each cancel it. A test of the
  controls found this: it read a station that started itself.
- **The `Live` badge held one name for two places.** `MyHiFiWeb.PlayerLive` draws it on
  the faceplate and in the large view, so a live stream with the large view open gave
  two elements of the same name, which breaks the DOM patching of LiveView. The caller
  gives the name now. A test of the transport row of a radio station found this.

Two changes that this plan did not name.

- **A play of another track writes the place of the track that plays.** A move is a
  play, so next and previous need this, and a person who picked another episode from
  the list lost the place of the one that played. Section 5.6.1 of the specification
  named five moments and not this one.
- **`MyHiFiWeb.BrowseLive` reads `capabilities/0` for the search field.** It called
  `search/2`, read `{:error, :not_supported}`, and held the answer in its own state,
  because the behaviour gave no way to ask in advance. A person met a flash message
  that named their own search as an error.

## 10. Changes to the specification

- **Section 5.1** gains `capabilities/0`, `next/1` and `previous/1` in the list of
  callbacks, the list that each source of this firmware gives, and the order that
  next and previous move through.
- **Section 5.5** gains `Player.Paused`, and the new field of `Player.Started`.
- **Section 5.6** gains the four commands, and `paused?` in the state.
- **Section 9** loses the sentence "No interface holds a control that moves through a
  stream". It gains the skip, the format that holds one, and the way that a pause and
  a standby work together.
- **Section 10** gains the transport row of the large view.
