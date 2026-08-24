# Plan: download an episode, and read through it

- Date: 2026-08-24
- Status: done. 591 tests pass, `mix check` is green, and an episode played on the
  board on 2026-08-24. The read found four faults of the output path, and three of
  them were not in this plan at all. See step 8.
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

A person cannot listen to a podcast on this device today. A read on the board on
2026-08-24 gave sound that a person called "extremely distorted", and the log says
why: the source dropped the oldest 64 KB of the audio **1259 times** during two
plays of one 49.7 MB episode.

`MyHiFi.Player.HttpSource` reads the body with `Req` and `into: :self`. The
documentation of `Req` names that mode a "firehose": each part reaches the mailbox
of the element as soon as it arrives. The demand of Membrane governs the pad of the
element, so it decides what leaves. It cannot reach a socket that Finch owns, so it
does not decide what arrives.

A live stream arrives at about the bitrate of the audio, so the wire gives the
pacing and the queue stays near the low mark. The docstring of the element states
that. A podcast server sends a whole file at the speed of the network, so the queue
passes its limit of 8 × 64 KB and `trim/1` drops the oldest bytes. 64 KB is about 4
seconds of sound, and `trim/1` is not at fault: it is the guard that keeps the board
alive, and it meets a stream that no person wrote it for.

**This plan holds the answer of James: read the episode into the cache as fast as
the network allows, and play from the file while it grows.** A local file needs no
flow control at all.

## 2. Decisions

| Question | Decision |
|---|---|
| Where does the file live? | The cache, namespace `download`, keyed by the identifier of the episode. Section 13 of `docs/spec.md` already names both. |
| Does playback wait for the whole file? | No. It begins when the file holds enough, and the reader follows the writer. |
| Does a stop end the download? | No. The request is in flight, so it continues to the end. A CDN often sends the whole file before a person stops, and the next play then reads a whole file. |
| What writes the file? | `Req` with `into: fun`, and the function writes each part with `IO.binwrite/2`. |
| What reads the file? | `MyHiFi.Player.FileSource`, a new element with manual flow control. |
| How exact is a resume? | Exact. The episode holds `position_bytes` beside `position_ms`. |
| Does an eviction take an episode in play? | No. `keep?` holds it, and section 13 already says so. |
| Does a live stream change? | No. `HttpSource` keeps its shape, and internet radio keeps its path. |

### 2.1 Why `into: fun` and not `into: File.stream!(path)`

`Req` writes a collectable for a status of 200 alone. `Req.Finch` holds this:

```elixir
{:status, 200}, ... -> Collectable.into(collectable)
{:status, status}, ... -> Collectable.into("")
```

A resume of a download asks for a range, and a server answers 206. `Req` would then
collect the body into a binary in memory, and that is 50 MB of the 363.9 MB of this
board. `into: fun` runs for each part whatever the status is, so the function writes
the part and gives `{:cont, …}`. It also gives `{:halt, …}`, which stops a download
at once and needs no kill.

### 2.2 Why the partial file lives outside the cache

`MyHiFi.Cache.Entry.Changes.Write` creates the row and the file together, and its
docstring holds the reason: "a row that exists names a file that exists". A file
that grows breaks that.

The download therefore writes `<cache>/download/<episode id>.part`, and the cache
gets an entry when the file is whole. The invariant of the cache stays true, and the
accounting of the cache never holds a size that is about to change.

This needs one new thing: **a sweep of every `.part` file at boot**. A download that
an interruption stops leaves such a file, and no row names it. Without the sweep
those files fill the partition, and no eviction can see them.

## 3. The modules

Three new files, and no more.

**`MyHiFi.Player.Download`** holds one download. A `DynamicSupervisor` starts it,
and the identifier of the episode names it in a `Registry`, so a second play of one
episode finds the first download and starts no other.

- It writes to `<cache>/download/<episode id>.part`.
- It asks for a range when that file already holds bytes, and it appends. A server
  that answers 200 and not 206 ignored the range, so the process truncates the file
  and begins again.
- It publishes `{:download, {:bytes, count}}`, `{:download, :done}` and
  `{:download, {:error, reason}}` to each process that watches it.
- **A stop of the playback does not end it.** The request is already in flight, and a
  CDN often sends the whole 50 MB before a person stops. It therefore holds no link
  to the pipeline: it finishes the file, it puts the entry in the cache, and it
  stops by itself. The next play of that episode reads a whole file, so it needs no
  network and it begins at once.
- On `:done` it puts the file in the cache with `keep?: true`, it removes the
  `.part` name, and it calls `MyHiFi.Cache.prune/0`. The artwork path already calls
  `prune` at the moment that the cache grows.

**`MyHiFi.Player.FileSource`** reads that file. It follows `HttpSource`: an output
pad with `flow_control: :manual` and `demand_unit: :bytes`, a `demand` counter, and
a `serve/1` that gives no more than the demand.

- It holds `filling?`, as `HttpSource` does, so nothing leaves it until the file
  holds `buffer_bytes`.
- It reads with `:file.pread/3` from its own offset, so it needs no queue in memory.
  The file is the buffer.
- At the current end of a partial file it gives no buffer and it waits. The next
  `{:download, {:bytes, _}}` message wakes it.
- It gives `end_of_stream` when it reaches the end of a file that `:done` named.
- It monitors the download. A download that dies with no `:done` raises here, and
  the player then does what it does for any pipeline that fails.

**`MyHiFi.Player.Download.Supervisor`** is the `DynamicSupervisor` and the
`Registry`. It also holds the sweep of section 2.2, which runs when it starts.

## 4. The exact resume

This drops the largest open risk of `docs/podcasts-plan.md`. A sweep of 46 real
episodes on 2026-08-24 found that **11 of them hold more than one bitrate**, and a
resume of one of those landed as much as 1994.6 s from the mark. The bitrate of the
first frame is exact for a constant bitrate file alone.

**A local file needs no bitrate.** The source knows the byte that it has reached,
and the player knows the time. `MyHiFi.Player` therefore stores both:

- `position_ms`, as it does now.
- `position_bytes`, a new attribute of `MyHiFi.Podcast.Episode`.

A resume opens the file at `position_bytes`, so the error of a variable bitrate
episode goes to zero. `MyHiFi.Player.Mp3` stays for nothing else, so it goes with
the last user of it.

The skew between the two numbers is the latency of the pipeline: the samples in
front of the sink, and the buffer of ALSA. A measurement on 2026-08-21 gave 35 to
245 ms from a stop to silence, so the skew is under a quarter of a second. That is
four orders of magnitude better than 1994.6 s.

**The place is in front of the sound, so a resume steps back.** The reader reports
the byte that it read, and the pipeline holds a lead over the sound of 1.7 s to
3.8 s. `MyHiFi.Player.Mp3Frame` therefore steps back 96 KB and lands on a frame
boundary, so a person hears about two seconds again and never loses a word. It reads
a window of about 10 KB and walks forward, because an MP3 frame holds no pointer to
the one before it.

**A seek needs more, and version 1 holds no seek.** A seek to a place that no person
reached needs a true map from time to byte, and that map needs a walk of every
frame. The count that a page shows also needs the timeline of the decoder in the
place of the clock of the player. Write both when a seek control arrives, and not
before.

## 5. The stop

James asked for a stop that answers at once. The pipeline may take its time, and the
sound must not.

`MyHiFi.Player.handle_call(:stop, …)` today stores the place, waits up to 5 seconds
for `Membrane.Pipeline.terminate/2`, and then answers. A measurement on 2026-08-24
gave 5055 ms for a podcast, and the caller gave up at its own 5 second timeout while
the player finished the work. `MyHiFi.Playback.stop!/0` then raises, so a page that
a person uses breaks.

The new shape:

1. `handle_call(:stop, …)` stores the place, tells the sink to be silent, publishes
   `Stopped`, and answers `:ok`.
2. It returns `{:noreply, state, {:continue, {:terminate, pipeline}}}`.
3. `handle_continue({:terminate, pipeline}, state)` holds the wait.

`handle_continue/2` runs before the process takes another message, so a `play` that
follows still cannot start until the sound card is free. The reason that
`stop_pipeline/1` waits stays served: a new pipeline that finds the card busy dies
with `:epipe`. The wait moves onto the path of `play`, which already allows 30
seconds.

**The sink is the null sink, and no child changes.** `MyHiFi.Output.APlaySink` gets
a message, closes its `aplay` port, and drops each buffer that arrives after that.
Closing the port is what gave the 35 to 245 ms of silence in the measurement of
2026-08-21.

`handle_call({:standby, true}, …)` holds the same three lines as the stop, so it
gets the same treatment.

## 6. Changes outside the new files

- **`MyHiFi.Source`, the `transport` type.** Add `:download`. `MyHiFi.Player.Pipeline`
  already chooses the source with a clause for each transport, so this adds a third
  clause and changes neither of the other two.
- **`MyHiFi.Source.Podcasts.resolve/1`** gives `transport: :download` and the
  identifier of the episode. It no longer builds a `range` header, and it no longer
  calls `MyHiFi.Player.Mp3`.
- **`MyHiFi.Podcast.Episode`** gains `position_bytes`, and `store_position` accepts
  it. A migration follows.
- **`MyHiFi.Player`** stores the byte with the time, and it holds the new stop of
  section 5.
- **`MyHiFi.Output.APlaySink`** answers the message that makes it silent.
- **`MyHiFi.Cache.Entry`** gains a `put_file` action. It takes a path, and
  `MyHiFi.Cache.Entry.Changes.Write` moves that file into the cache with
  `File.rename/2`. Both paths sit on one partition, so the move is atomic and it
  copies no byte. `byte_size` comes from `File.stat/1`.

  **It writes no checksum.** `AshStorage` allows nil there, and nothing in this
  firmware reads the field: `MyHiFi.Artwork` and `MyHiFi.Player.FileSource` both
  read a file by its path. An md5 of 50 MB costs about a second of the CPU of this
  board and it would answer no question. The check that matters is whether the
  whole file arrived, and `MyHiFi.Player.Download` gets that for nothing by a
  comparison of the bytes that it wrote against the `content-length` of the answer.
- **`MyHiFi.Application`** starts `MyHiFi.Player.Download.Supervisor`.

## 7. Risks and unknowns

| Item | Risk | Action |
|---|---|---|
| The rule against a buffer on the card | CLAUDE.md and section 13 of the spec both say "Never buffer the stream on the SD card". | Narrow the rule to a live stream. Section 13 gives the reason for it: "A buffer on the SD card would write all the time, and that shortens the life of the card." A download writes one file one time, and then it reads. The reason does not reach it. |
| The life of the card | An episode is about 50 MB. Two hours of listening each day is about 115 MB each day, and 42 GB in a year. | Measure the size of a real episode, and hold the number in section 17. A person who listens to one episode two times writes it one time, because the cache holds it. |
| The room on the partition | 14.4 GB is free, and the cache limit is 12.45 GB. | The eviction holds the limit, and `keep?` holds the episode in play. Release the mark when the episode is played. |
| A `.part` file that nothing names | An interruption leaves such a file, and no eviction sees it. | The sweep of section 2.2. Measure that it runs. |
| The reader that reaches the writer | A network slower than the audio gives silence, and not a fault. | The reader waits, and the player shows the buffering state. This is what a live stream does today. |
| The time to the first sound | The reader waits for `buffer_bytes` on the disk. | Measure it. The number to beat is the 1.3 s of an MP3 stream on 2026-08-22. |
| A server that refuses a range | A resume of a download then gets 200 and the whole file. | Truncate and begin again. Section 3 holds it. A download that continues past a stop makes this path rare: it happens after an interruption of the power or of the network alone. |
| The skew of `position_bytes` | The byte and the time come from two ends of the pipeline. | Under a quarter of a second. See section 4. |
| Two plays of one episode | A second play must find the first download. | The `Registry` of section 3. |
| The live path keeps the firehose | `HttpSource` still holds no flow control, and a live server that sends a burst would drop audio. | Not open today, because the wire gives the pacing. Hold the reader process with `into: fun` for the day that it is. |

## 8. Order of work

1. ~~Add `put_file` to `MyHiFi.Cache.Entry`.~~ Done on 2026-08-24, and it writes no
   checksum. See section 6 for the reason. `MyHiFi.Cache.Entry.Changes.Write` now
   takes the `bytes` argument or the `path` argument, so the two ways in share the
   fields that they both need.
2. ~~Build `MyHiFi.Player.Download`, with the sweep.~~ Done on 2026-08-24, with 16
   tests. It needs no supervisor of its own: `MyHiFi.Application` holds the registry
   and the dynamic supervisor, and it calls `sweep/0` beside `migrate/0`. Three
   faults that the tests found:

   - **A `:raw` file belongs to the process that opened it.** The process that holds
     the request therefore opens the file as well, and it closes it in an `after`.
     Any other process gets `:not_on_controlling_process`.
   - **A caller that subscribes after it asks misses the whole download.** A small
     episode over a fast network finishes first, so `ensure/2` puts the caller in the
     state of the new process instead.
   - **A download can finish between `start_child` and the join of a second caller.**
     That call then exits, so `join/4` catches it and reads the cache one more time.

   It also needed a one-shot flag for the server that ignores a range: the truncate
   belongs to the first part of the answer, and a guard alone would empty the file
   on each part.
3. ~~Build `MyHiFi.Player.FileSource`.~~ Done on 2026-08-24, with 17 tests. It reads
   with `:file.pread/3` from an offset that it holds, so it needs no queue at all.
   It reads no further than the count that the download reported, even when the file
   holds more, because a later message names what the file really holds.
4. ~~Add `:download` to the transport type, the clause of the pipeline, and
   `resolve/1` of the podcast source.~~ Done on 2026-08-24. The playable gains `key`
   and `position_bytes`, and `resolve/1` builds no `range` header any more.
5. ~~Add `position_bytes`, the migration, and the store of both numbers.~~ Done on
   2026-08-24. `MyHiFi.Source.store_position/2` takes a place and not a number, so
   this firmware holds one way to store a place and not two. The element tells the
   pipeline each 16 KB, which is about one message each second of a 128 kbit/s
   episode, and the pipeline tells the player.
6. ~~Change the stop and the standby of `MyHiFi.Player`, and the silence of
   `MyHiFi.Output.APlaySink`.~~ Done on 2026-08-24, with 4 tests. The sink needed a
   `handle_buffer/4` clause for no port: it held two clauses and both guarded on
   `is_port(port)`, so a buffer after a close would have raised.
7. ~~Remove `MyHiFi.Player.Mp3` and its tests, because nothing calls it.~~ Done on
   2026-08-24.

   Sobelow and credo then asked for three things, and two of them were real.
   `MyHiFi.Cache.Entry` now constrains the namespace and the key, because both become
   the path of a file and a caller could have named a parent directory. The two paths
   of `MyHiFi.Player.Download` come from the device alone, so those name the check
   that they answer.
8. ~~Play an episode on the board. Stop in the middle, and confirm the resume with a
   person who listens.~~ Passed on 2026-08-24, at the fourth attempt.

   **The plan named one fault and there were four.** The flow control was real: the
   log held 1259 dropped buffers. It was not the reason that a person heard noise.

   - The reader gave the decoder the whole file in one buffer, and
     `Membrane.MP3.MAD.Decoder` decodes a whole buffer in one callback. That asked
     for 822 MB of samples on a board that holds 363.9 MB.
   - The card cannot play 44100 Hz cleanly. A 440 Hz tone straight to `aplay` was
     rough at 44100 Hz at two levels and clean at 24000 Hz and 48000 Hz. **This one
     was never a fault of this work**, and radio hid it because both RNZ streams
     hold 24000 Hz.
   - The queue of a port has no limit, so nothing paced the pipeline, and Membrane
     gives a pad that counts bytes 600,000 of them. Together they put the reader 31
     seconds in front of the sound, so the resume was 31 seconds out.

   Section 17 of the specification holds each measurement.
9. Measure: the time to the first sound, the size of an episode, the memory during a
   download, and the time of the sweep. Record each one in section 17 of the spec.

## 9. Changes to the specification

`docs/spec.md` changes in the same commit as the code:

- Section 6 gains the download path of an episode, beside the HTTP and HLS paths.
- Section 13 point 2 stops naming a later version, and it describes the namespace.
- The last paragraph of section 13 narrows to a live stream, with the reason of
  section 7 of this plan.
- Section 5.1 gains `:download` on the `transport` type.
- Section 9 describes a resume by byte, and not by bitrate.
- Section 15 loses the four rows that this work closes, and it keeps the row for the
  live path of `HttpSource`.

`CLAUDE.md` narrows its rule about the SD card in the same way.
