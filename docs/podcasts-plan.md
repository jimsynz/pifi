# Plan: podcasts as the second source

- Date: 2026-08-23
- Status: every step is done. Step 10 passed on the board on 2026-08-24, after four
  faults of the output path came out. See `docs/episode-download-plan.md`.
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

Add podcasts as the second `MyHiFi.Source`. Internet radio is the first one, and
the point of the behaviour is that the player and the two user interfaces do not
change when a source joins. This plan holds the places where that is true, and the
three places where it is not.

Section 3 of `docs/spec.md` puts podcasts outside version 1. This work moves them
inside it, so that section changes with the code.

## 2. Decisions

| Question | Decision |
|---|---|
| How does a person find a show? | The Podcast Index. |
| Where does the key come from? | A person enters the key and the secret on the settings page. |
| Where do the episodes come from? | The RSS feed of the publisher, and not the index. |
| How does a person subscribe? | `favourite/2` on the show. A container gets a `favourite?` field. |
| What happens at the end of an episode? | The player stops, and it marks the episode played. It also keeps the position. |
| Does this version hold m4a? | No. A measurement says why. See section 9. |
| Does this version hold pause, seek, or download? | No. Section 13 of the specification keeps a download for a later version. |

An episode list comes from the feed, and a show comes from the index. The two have
different needs. Playback must work when the index does not answer, and a
subscription must not stop when a key expires. A feed also holds a new episode
before the index reads it, and it gives the enclosure address that the publisher
intends. A person who subscribes therefore relies on the publisher alone.

## 3. Packages

I tested each candidate against Elixir 1.20 and OTP 29 on 2026-08-23. I built
each one, and I ran it on real feeds.

| Package | Result |
|---|---|
| **`saxy` 1.6.1** | **Use it, and it is the only new package.** Pure Elixir, and it holds no dependency of its own. 9 million downloads, and a release on 2026-07-10. `Saxy.Partial` gives it one chunk at a time. |
| `fiet` 0.3.0 | Read, and not used. See below. |
| `feeder` 2.3.2 | Cannot build. Its vendored `erlang.mk` calls `file:pid2name/1`, and OTP removed that function. |
| `metalove` 0.5.0 | Not usable. It needs `timex`, which needs `tzdata`, which needs `hackney`. `hackney` 1.25.0 holds four advisories, and one of them is HIGH. It also gives this firmware a second HTTP client. |
| `elixir_feed_parser` 2.1.0 | Needs `timex`. Last release 2018. |
| `fast_rss` 0.5.0 | A Rust NIF. This target gets no precompiled artefact. |
| `feedex`, `elixir_rss`, `podcast_parser` | Each one needs `httpoison` or `timex`. Each is from 2018 to 2021. |
| `date_time_parser` 1.3.0 | Gives wrong answers. It reads `Thu, 02 Jun 2022 14:00:00 -0500` as `~N[2022-06-02 14:00:00]`, and it removes the offset. |
| `calendar` 1.0.0 | Needs `tzdata`. |
| `podcast_rss` 0.3.0 | It writes a feed. This firmware reads one. |
| `chapters` 1.0.1, `polyvox_id3` | Chapter marks are outside this version. |
| `opml` 0.2.0 | A subscription import is outside this version. |
| `membrane_mp4_plugin` 0.36.10 | Not needed yet. See section 9. |
| `itunes_api`, `itunes` | The decision names the Podcast Index, and not Apple. |

`tzdata` is the reason that four of these fail. It writes to disk, it holds an
updater that reaches the network, and a Nerves target must then get a writable
data directory and a configuration that stops the updater. No date needs that
cost, so `MyHiFi.Podcast.Feed` reads an RFC 2822 date itself. That is about 30
lines, and a month table.

The Podcast Index needs no package. Its four headers are `X-Auth-Key`,
`X-Auth-Date`, `Authorization`, and `User-Agent`. The `Authorization` header is
`sha1(key <> secret <> date)` as lower case hexadecimal, so `:crypto` and
`Base.encode16/2` give it. `req` is already in the tree.

### Why not `fiet`

`fiet` reads RSS 2.0 on top of `saxy`, and its `extras` option reads the iTunes
namespace. I tested it, and it works. Two facts moved the decision.

Its public `parse/1` reads a whole binary, and it gives no way to stream. The
streaming path goes through `Fiet.StackParser`, which is `@moduledoc false`. So the
plan called a private module of a package with no release since 2020-07-06.

A copy of the package removes that risk and adds another. The RSS 2.0 path is 531
lines across 7 files, out of 1298 in the package, and it reads all of RSS 2.0. This
firmware reads 12 elements.

`MyHiFi.Podcast.Feed.Parser` is therefore ours. It is a `Saxy.Handler`, it reads
those 12 elements, and it steps over every other one. `saxy` is a first tier
dependency, so nothing here relies on a package that no person maintains.

## 4. Data model

A new domain, `MyHiFi.Podcast`, with two resources. It follows `MyHiFi.Radio`.

`MyHiFi.Podcast.Show`:

| Attribute | Note |
|---|---|
| `id` | A UUID. |
| `feed_url` | The address of the feed. An identity, so a refresh updates and does not duplicate. |
| `index_id` | The feed identifier of the Podcast Index. It is absent for a show that a person added by address. |
| `title`, `author`, `description` | From the feed, and from the index before the first read. |
| `artwork_url` | The artwork cache holds a copy. |
| `subscribed?` | A person subscribed. The refresh job reads only these. |
| `last_fetched_at`, `last_error` | The refresh job writes both. A page shows a feed that fails. |
| `timestamps()` | |

`MyHiFi.Podcast.Episode`:

| Attribute | Note |
|---|---|
| `id` | A UUID. |
| `show_id` | The show. |
| `guid` | The `<guid>` of the item. An identity with `show_id`, so a refresh updates and does not duplicate. |
| `title`, `subtitle`, `description` | From the item. |
| `audio_url`, `mime_type`, `byte_length` | From the `<enclosure>`. |
| `duration_ms` | From `itunes:duration`. It reads `3600`, `48:41`, and `01:02:13`. |
| `published_at` | From `<pubDate>`, as RFC 2822. |
| `artwork_url` | From `itunes:image` of the item, or of the channel. |
| `position_ms` | Where the person stopped. |
| `played?` | The episode reached its end. |
| `timestamps()` | |

### 4.1 What step 2 built, on 2026-08-23

Actions on `Show`: `read`, `destroy`, `subscriptions`, `upsert_from_feed`,
`upsert_from_index`, `subscribe`, `unsubscribe`, and `record_error`.

Actions on `Episode`: `read`, `destroy`, `by_show`, `upsert_from_feed`,
`store_position`, `mark_played`, and `record_length`.

Five differences from the list above, and the reason for each one:

- **`by_feed_url` is a code interface and not an action.** `define
  :get_show_by_feed_url, action: :read, get_by: [:feed_url]` gives it, in the same
  way that `MyHiFi.Radio` gives `get_station`. One action less.
- **`refresh` and `refresh_all` are not here.** Each one needs the job, and the job
  is step 9. An action with no body belongs with its body.
- **`upsert_from_index` uses `upsert_fields [:index_id]`.** A row that already
  exists therefore takes the identifier of the index and nothing else, because the
  publisher owns the title and the description. A show that no feed read yet takes
  each field, because `upsert_fields` decides the conflict alone. This is how "the
  feed wins" becomes one line of the DSL.
- **`record_error` and `record_length` are new.** `last_error` had no writer, and
  section 10 asks the player to write the length of an episode that its feed does
  not give. Each one is an `accept` and nothing more.
- **A local search is not here.** The source searches the index, so nothing calls
  a search of the local rows. Add it when a person holds enough subscriptions to
  need it.

Two facts that a later step needs:

- **SQLite holds the foreign key, so the episodes of a show go before the show.**
  A test covers this. The refresh job and the source both meet it.
- **`published_at` is `utc_datetime_usec`**, and a `<pubDate>` holds whole seconds.
  Compare such a value with `DateTime.compare/2`, and not with `==`.

The tables are `podcast_shows` and `podcast_episodes`, and one migration makes
both. 34 tests cover the two resources.

`refresh_all` is an AshOban scheduled action, in the shape of
`Station.sync_from_remote`. A feed changes more often than a station list, so it
runs each six hours and not each week. It reads the subscribed shows only.

Two settings hold the key: `podcast_index_key` and `podcast_index_secret`.
`MyHiFi.Settings` already holds a key and a value, and the database is on the
`/root` partition. `MyHiFi.DeviceSecrets` is not the place: it writes a secret that
the device makes for itself, and this one comes from a person.

The refresh job keeps the newest 200 episodes of a show, and it removes the rest.
A feed of 2955 episodes gives no benefit to a person with a knob, and the database
is on an SD card.

## 5. The feed reader

### 5.1 `MyHiFi.Podcast.Feed.Parser` — written on 2026-08-23

A `Saxy.Handler`. A caller gives the bytes as they arrive, and gets a show and its
episodes. It holds no copy of the document.

```elixir
{:ok, parser} = Parser.new(max_items: 200)
{:cont, parser} = Parser.feed(parser, chunk)
{:ok, feed} = Parser.finish(parser)
```

`feed/2` gives `{:done, feed}` when it holds `max_items` episodes. The caller then
stops the download. A feed writes the newest episode first, so the rest of the
document holds older episodes only.

It reads these 12 elements, and it steps over every other one at no cost:

    channel   title, description, itunes:author, itunes:image, image/url
    item      title, guid, pubDate, description, itunes:subtitle,
              itunes:duration, itunes:image, enclosure

Six decisions inside it:

- **RSS 2.0 alone.** Apple asks each publisher for RSS 2.0, and all 49 feeds of the
  measurement send it. An Atom document or an HTML error page gives
  `{:error, :not_rss}` at the root element, and it reads no more.
- **The whole path decides an element**, and not its name. `<image><title>` of a
  channel is not the title of the show, and `<title>` of an item is not the title
  of the show either.
- **Text accumulates for a captured element alone.** An element that the firmware
  does not read costs nothing. An element inside a captured one keeps its text with
  the outer one, because some publishers write the show notes as XHTML inside
  `<description>`.
- **32 KB of text for one element.** A person writes far less. Some feeds hold a
  picture inside the description as base64, and 200 of those would end the
  firmware.
- **An item with no enclosure gives no episode.** A feed holds such an item for a
  post that carries text alone, and no such post can play.
- **The address of the audio identifies an episode with no `guid`.** A `guid` is
  not compulsory in RSS 2.0.

It also reads the two forms that a feed writes a length and a date in. RFC 2822
section 4.3 decides the zone: a numeric offset, one of the names of that section,
or an unknown name, which that section reads as no offset. `published_at/1` keeps
the offset. No package does, and that is why `date_time_parser` is not in the
plan.

### 5.2 What the measurement says

I read the feeds of the 50 most popular New Zealand podcasts on 2026-08-23. One
address gave no answer, and 49 gave a feed.

| Result | Number |
|---|---|
| Feeds read with no error | 49 of 49 |
| Episodes read | 8773 |
| Episodes where the count matches the `<item>` count of the document | 8773 of 8773 |
| Bytes read | 149 MB |
| Slowest feed | 32 ms |
| Largest memory for one feed | 7.0 MB |
| Audio addresses that are not HTTP | 0 |

How often a publisher writes each element, across those 8773 episodes:

| Element | Present |
|---|---|
| `guid`, `title`, `enclosure`, `pubDate`, `description` | 100% |
| `itunes:duration` | 8767 of 8773 |
| `itunes:image` | 70% |
| `enclosure length` | 61% |
| `itunes:subtitle` | 25% |

The show read a title, a description, an author and artwork for all 49.

`enclosure length` at 61% matters for one thing. Section 8 uses that length and
the duration to turn a position into a byte offset. Two of five episodes hold no
length, so those episodes need another way, or they start again from the
beginning.

The episode count and the `<item>` count agree for every feed, so the reader drops
no episode and it invents none. 36 tests and 7 doctests cover the reader, and each
one reads the feed in 8 byte chunks. One test reads the same feed in chunks of 1,
2, 3, 7, 13, 64 and 1024 bytes, and it asks for one answer, so no element can
depend on where a chunk ends.

### 5.2.1 The extended namespaces, and why the reader holds none of them

Three other elements can carry a byte length, and the reader reads none of them.
This is a count and not a preference.

| Element | Feeds that hold it |
|---|---|
| `<media:content>` of Media RSS | 12 of 49 |
| `<media:content fileSize=…>` | 4 of 49 |
| `<podcast:alternateEnclosure>` of Podcasting 2.0 | 2 of 49 |
| `<link rel="enclosure" length=…>` of Atom | 0 of 49 |
| A `bitrate` attribute on any of them | 0 of 49 |

**None of them gives one length that `<enclosure>` does not give already.** Of the
18 feeds that write no `length`, **0** hold `fileSize` or
`podcast:alternateEnclosure`. All 4 feeds that hold `fileSize` write the
`<enclosure>` length as well. So a reader for these elements would add code and no
fact.

The Atom form is real in the specification and absent in practice. All 50 addresses
send RSS 2.0, so the reader refuses Atom and loses nothing.

The other Podcasting 2.0 elements, for a later version:

| Element | Feeds | Note |
|---|---|---|
| `<podcast:transcript>` | 10 of 49 | The widest adoption of any extension here. A screen with 4 lines and a knob cannot show a transcript, so this waits for a reason. |
| `<podcast:guid>` | 6 of 49 | It identifies a show across a change of its address. See section 10. |
| `<podcast:locked>` | 4 of 49 | It is about who owns a feed, and a player needs none of that. |
| `<podcast:season>` | 1 of 49 | |
| `<podcast:chapters>`, `<podcast:person>`, `<podcast:funding>`, `<podcast:soundbite>`, `<podcast:value>`, `<podcast:episode>` | 0 of 49 | |

### 5.3 `MyHiFi.Podcast.Feed` — written on 2026-08-23

It holds the HTTP part. `Req` streams the answer into the parser through an `into:`
function, and it stops the download when the parser gives `{:done, feed}`.

Four decisions inside it:

- **`retry: false`.** This is not a choice about how much a device should try. A
  retry runs the collector a second time, and the parser then already holds the
  elements of the first try, so the second gives a parse error. The refresh job is
  an Oban job with `max_attempts`, and that is the layer that tries again.
- **It reads no body for a status that is not 200.** The status arrives before the
  body, so a page that says "not found" costs one request and no parse.
- **A compressed answer gives `{:unsupported_encoding, encoding}`.** `Req`
  decompresses no body that streams into a function, and it therefore asks for
  none. This names the cause instead of giving a parse error for bytes that are not
  XML.
- **32 MB stops a feed.** The largest of the measurement is 13.6 MB.

### 5.4 What the reader saves

The early stop is the reason for the streaming design, and this is what it gives
across the 49 feeds:

| | |
|---|---|
| Feeds that stopped before the end | 41 of 49 |
| Bytes in the whole feeds | 149 MB |
| Bytes that the reader reads | **44 MB, which is 30%** |
| The largest feed | 13.6 MB, and it reads 3.5 MB |

I also read all 50 addresses over the network, and not from a copy on disk. **50 of
50 gave a show and its episodes**, and that includes the one address that a plain
`curl` could not read. 8973 episodes, 42 feeds reaching the limit of 200, the
slowest at 3.0 s, and 8.3 MB of memory for the largest.

13 tests cover the HTTP part, with a stub in the shape that
`MyHiFi.Radio.RadioBrowser` uses. They cover a chunked answer, a 404, an empty
answer, an Atom document, a truncated document, a gzip answer, an identity answer,
a network fault, and a body above the limit.

## 6. `MyHiFi.Podcast.Index` — written on 2026-08-23

The client of the Podcast Index. It follows `MyHiFi.Radio.RadioBrowser`: one
private `request/2`, and `Application.get_env/3` for a test to give a stub plug.

| Function | Endpoint |
|---|---|
| `search/2` | `/search/byterm` |
| `show_by_feed_url/1` | `/podcasts/byfeedurl` |
| `trending/1` | `/podcasts/trending`, with `cat` and `lang` |
| `categories/0` | `/categories/list` |
| `configured?/0` | Nothing. It reads the settings. |
| `signature/3` | Nothing. It is the hash of the index. |
| `show/1` | Nothing. It maps a feed of the index to the attributes of `Show`. |

`search/2` and `trending/1` give a list of maps that
`MyHiFi.Podcast.upsert_show_from_index/1` accepts as it is. A test writes a row
from a search answer with no change between them.

Five decisions inside it:

- **`signature/3` is public.** It is the one part of this module that the service
  defines, so a doctest holds a value that no Elixir code computed. `sha1sum` and
  `openssl dgst` both give `73a1fffed61c1d30d858beb1fc48f355386449d2` for the
  example key and secret of the documentation of the index. A test that recomputed
  the hash with the same expression would prove nothing.
- **The clock comes first.** `X-Auth-Date` holds a window of 3 minutes, and a board
  with no battery starts in 1970. `check_clock/0` asks `nerves_time` and gives
  `{:error, :clock_not_synchronised}`, because a 401 tells a person nothing about
  the cause. `nerves_time` is a target dependency, so `Mix.target()` branches that
  function, as `MyHiFi.Setup` branches its own.
- **A 401 gives `:key_refused`, and no key gives `:no_api_key`.** The two are
  different messages for a person: one says that the key is wrong, and one says
  that there is none. A device with no key reaches no network at all.
- **`credentials/0` holds no check for a blank key.** `MyHiFi.Settings.Setting`
  removes the space around a value and refuses one that then holds nothing, so a
  stored key always holds a character. A test covers that, and the check came out
  when the test found it.
- **`show/1` gives `nil` for a feed with no address or no title**, because neither
  can become a row. `artwork` comes before `image`, and `author` before
  `ownerName`.

24 tests, and each stub sends the request back to the test, so a test reads the
headers and the query that the client built.

### 6.1 Read against the real service on 2026-08-23

Every function ran against the real index with a real key, at an `iex` prompt.

| Check | Result |
|---|---|
| `search/2` | 5 shows, with the feed address and the index identifier of each |
| `categories/0` | 112 categories |
| `trending/1` | 5 shows |
| `trending/1` with `category: "History"` | 5 shows |
| `show_by_feed_url/1` | The show, with its index identifier |
| A feed that the index does not hold | `{:error, :not_in_index}` |
| index → `Show` → feed → `Episode` | 50 episodes, and `index_id` survived the feed read |

**One fault came out of that read, and the stubs could not have found it.** The
index answers **400** for a feed that it does not hold, and not 200 with an empty
feed. `show_by_feed_url/1` therefore gave `{:unexpected_status, 400}`, and a caller
cannot read that as "the index does not hold this feed, so read the feed
yourself". That is the private feed path, and it is the reason that this plan keeps
an RSS reader at all. The function now reads a 400 from that one endpoint as
`:not_in_index`. A 400 from `/search/byterm` stays a status error, because there it
means a bad request.

The whole path also showed that `index_id` survives a feed read that replaces the
title, which is what `upsert_fields [:index_id]` promised.

## 7. `MyHiFi.Source.Podcasts`

The tree, next to the three branches of the radio:

```
Subscriptions       the shows that a person subscribed to
  <show>            the episodes of that show
Trending            the trending shows of the index
Categories          one container for each category of the index
  Comedy            the trending shows of that category
```

- A show is a container, and an episode is a track.
- `search/2` gives the shows of the index as containers. A person opens one, and
  the source then reads the feed and shows the episodes. The show needs no
  subscription first.
- `browse/2` on a show reads the local episodes. It reads the feed when the local
  copy is absent, or older than one hour.
- `favourite/2` on a show calls `subscribe` or `unsubscribe`. On an episode it
  gives `{:error, :not_supported}`.
- `icon/0` gives `:podcast`. `MyHiFiWeb.CoreComponents` already draws that name as
  `hero-microphone`, and the device screen is a later version.
- `ref_to_string/1` names an episode as `episode:<uuid>`, and it gives
  `{:error, :cannot_name}` for anything else. This follows `station:<uuid>`.
- `resolve/1` gives `transport: :http`, `container: :none`, `format: :mp3`, and
  `live?: false`. It adds a `range` header when the episode holds a position. See
  section 8.
- `resolve/1` gives `{:error, {:unsupported_format, type}}` for an enclosure that
  is not MP3. See section 9.

`slug/1` gives `podcasts`, so the address is `/browse/podcasts`.

## 8. Changes outside the new files

Three, and no more.

**`MyHiFi.Source`, the `container` type.** Add `favourite?`, in the shape that
`track` already holds it. `nil` for a source with no mark on a container, so an
interface shows the control for `true` and for `false` only. Internet radio gives
`nil` on each of its containers, and it does not change. A later source gets the
same mark on an album and on a playlist.

**`MyHiFi.Player`, the end of a stream.** `handle_info({:pipeline_finished, …})`
starts the stream again today, and that is right for a station. An episode ends,
and it must stop. Read `live?` of the playable, which the player already holds:

- `live?: true` starts the stream again, as it does now.
- `live?: false` publishes `%Stopped{reason: :finished}`, and it tells the source.
  `Stopped` already carries a reason, so this needs no new event.

The player also stores the position when it stops, and when it enters standby. It
needs a callback for that, because the player holds no knowledge of a podcast. Add
`store_position(ref, position_ms)` to `MyHiFi.Source`, with a default of `:ok` in
a `@behaviour` that a source may ignore. Internet radio ignores it.

`position_ms/1` counts from `started_at`, so an episode that starts at an offset
must add that offset to the count. One field on the state, and one addition.

**`MyHiFiWeb.SettingsLive`.** A section for the key and the secret of the index,
with the address of the signup page. The secret shows as dots, and the page never
sends it back to the browser.

The browse page needs no change. It walks the tree of any source, and it already
draws the mark of a favourite. The `favourite?` field on a container reaches it
through the same path as the field on a track.

### 8.1 Where the length of an episode comes from

18 of the 49 feeds write no `length` on any enclosure, and 30 write one on every
episode. This is a choice of the publisher and not a gap, so a whole network gives
none. The average bitrate therefore has no value for 18 feeds in 49, and a resume
needs another source for the length.

I read the newest episode of each of those 18 feeds on 2026-08-23, three ways:

| Method | Result |
|---|---|
| `HEAD` | 18 of 18 give 200 with a `content-length` |
| `GET` with `Range: bytes=0-0` | 18 of 18 give 206 with a `Content-Range` |
| A plain `GET`, stopped at the first chunk | **18 of 18 give a `content-length`** |
| `accept-ranges: bytes` | 18 of 18 |

The three methods agree on every length. No host uses a chunked encoding.

**So the length needs no request of its own.** The player is about to `GET` the
audio to play it, and that answer already carries the length.
`MyHiFi.Player.HttpSource` reads the headers before it reads any audio, so
`Episode.record_length` runs at the start of the first play.

A `HEAD` would work, and it is the wrong choice here. It is one more request for a
fact that the next request gives, and the address of an episode is almost always a
tracking prefix such as `pdst.fm` or `podtrac.com`. A request that a publisher may
count is not one to make for nothing.

This also corrects an earlier line of this plan. It said that a person who stops
in the middle of a **first** play of such an episode loses the place. That is
wrong. The length arrives with the headers, before any audio, so it is already
stored when that person stops. No place is ever lost.

### 8.2 The resume, measured

I read 5 real episodes on 2026-08-23, walked every MP3 frame of each one to build a
true map from byte offset to time, and then asked where each way of computing an
offset actually lands.

**Every one of the five holds a single bitrate for the whole file.** A variable
bitrate was the risk that this plan carried, and it was the wrong risk. The
metadata of the feed was the real one.

| Where the numbers come from | Worst error, seeking to the middle |
|---|---|
| The `length` and `itunes:duration` of the feed | 227 s |
| The real `content-length` with the duration of the feed | 119 s |
| The bitrate of the audio | **0.03 s** |

The `length` of a feed is often not the length of the file. One episode named
14,165,913 bytes and sent 7,270,145. Another named 11,339,285 and sent 14,320,536.
A publisher who adds an advertisement at the time of the request changes the size,
and the feed keeps the old number.

**The middle row is what section 8.1 of this plan asked for**, and it is the worst
of the three. `Episode.record_length` would have written a real length beside a
stale duration, so it is gone. The measurement caught a fault that the plan itself
introduced.

`MyHiFi.Player.Mp3` therefore reads the bitrate from the header of the first frame
of the audio. Two requests and 4 KB, and only when a person resumes. An episode
with no place has never played, so a first play asks for nothing. A read that
fails starts the episode at the beginning, because repeating some audio is better
than stepping over some.

15 tests cover it, including a 40 KB ID3v2 tag, MPEG2 Layer III with its own
bitrate table, and a pattern that looks like a frame header and is not.

## 9. m4a, and why this version holds no MP4

I read the enclosure of each of the 50 top New Zealand podcasts on 2026-08-23. 48
send `audio/mpeg` only. One sends `audio/mpeg` and `audio/x-m4a`. One failed.

MP3 is therefore what a podcast is, and the pipeline already plays HTTP MP3 with
`membrane_mp3_mad_plugin`. `membrane_mp4_plugin` costs a dependency and a new
demultiplexer for one show in fifty, and it needs no decision now: `resolve/1`
gives `{:error, {:unsupported_format, type}}`, and the browse page shows the
message. Add the plugin when a person meets a show that needs it.

This follows the count of the 44 HLS stations in section 6.3 of the specification.
A count decides, and not a guess.

## 10. Risks and unknowns

| Item | Risk | Action |
|---|---|---|
| ~~`fiet` is not maintained~~ | Gone on 2026-08-23. `MyHiFi.Podcast.Feed.Parser` is ours, and `saxy` is its only dependency. | |
| ~~`Fiet.StackParser` is private~~ | Gone with the same change. | |
| A feed that no reader knows | 49 of 49 feeds read with no error, and those are the popular ones. A small publisher writes a stranger feed. | The reader gives an error and the show keeps its last episodes. `last_error` on the show holds the reason, and a page shows it. |
| A namespace prefix other than `itunes` | Legal, and no feed of the measurement uses one. Such a feed loses the length and the artwork of an episode. | Read the prefix from the declaration on the root element if a real feed needs it. |
| The key needs a person | The podcast source shows nothing until a person registers at the index and enters two values. | The settings page holds the address and the reason. Measure how a person finds this. |
| ~~The index client is not proven~~ | Proven on 2026-08-23. Every function ran against the real index with a real key, and that read found one fault that no stub could. See section 6.1. | |
| The clock at a first boot | The index holds a 3 minute window, and a board with no battery starts in 1970. | Ask `nerves_time` first, and give a reason and not a 401. |
| ~~Memory~~ | Measured on 2026-08-24. A refresh of 13 feeds needed 11.7 MB of the BEAM at its peak, and the memory available never went under 146.4 MB. | |
| Rate limits | The index publishes no number. A category page asks for the trending shows of each category. | Ask for one category at a time, and only when a person opens it. Hold the category list in the settings. |
| The position of an episode | **Open, and larger than this plan said.** A sweep of 47 feeds on 2026-08-24 walked every frame of each episode that its windows disagreed about. **11 of 46 episodes hold more than one bitrate**, one of them holds 9 and another holds 14. A resume of such an episode lands as much as 1994.6 s from the mark, where a constant bitrate episode of the same sweep landed 0.48 s away. Section 8.2 read 5 episodes and found no variable one, and 5 was too small a sample. The mechanism of the `range` header is still correct: 18 of 18 hosts answer with 206 and a `Content-Range`. | Read the true map from time to byte, or hold the byte offset next to the position. The bitrate of the first frame is not enough. |
| ~~An episode with no length~~ | Answered on 2026-08-23. The length of a feed decides nothing, so an absent one costs nothing. See section 8.2. | |
| A show that changes its address | `feed_url` identifies a show, so a publisher who moves their feed gives this device a second row. The subscription and every position stay with the old row. | `<podcast:guid>` names a show across such a move, and 6 of the 49 feeds hold one. The index also gives `podcastGuid` for each show that it holds, which reaches more shows than the feeds do. Neither one reaches a private feed. Decide this when a real feed moves, and not before. |
| Two sources of truth | The index gives a title, and so does the feed. | The feed wins, because the publisher owns it. The index fills a show that no feed read yet. |

## 11. Order of work

1. ~~Add `saxy` to `mix.exs`.~~ Done on 2026-08-23. It is pure Elixir and it holds
   no dependency, so it needs nothing from the Nerves system. Confirm the
   cross-compile with the first target build.
2. ~~Build `MyHiFi.Podcast`, `Show` and `Episode`, and the migration.~~ Done on
   2026-08-23. See section 4.1. A read of a real feed writes 200 episodes, and a
   second read of the same feed updates them and writes no more.
3. ~~Build `MyHiFi.Podcast.Feed` and its parser. Read the 50 feeds of the
   measurement.~~ Done on 2026-08-23. All 50 addresses gave a show and its
   episodes over the network. See sections 5.2 and 5.4.
4. ~~Build `MyHiFi.Podcast.Index`. Test it with a stub plug, and one time with a
   real key.~~ Done on 2026-08-23. Both. See sections 6 and 6.1.
5. ~~Add `favourite?` to the `container` type, and `store_position/2` to
   `MyHiFi.Source`.~~ Done on 2026-08-23. `MyHiFiWeb.BrowseLive` now draws one
   star for a track and for a container, and `docs/spec.md` section 5.1 holds
   both changes. The behaviour gains no `container/1`: see the note there for why
   the page writes the confirmed mark on a container instead of reading it back.
6. ~~Build `MyHiFi.Source.Podcasts`. Add it to the `:sources` list.~~ Done on
   2026-08-23. Read in a browser against the live index and live feeds: the tree,
   a search, a subscription, and the episodes of an 18 MB feed. That read found a
   layout fault that the tests could not. `docs/spec.md` sections 3, 7 and 8.1 now
   describe it.
7. ~~Change the player: stop at the end of an episode, store the position, and add
   the offset to the count.~~ Done on 2026-08-23. `MyHiFi.Source` gains a
   `finished/1` callback and the playable gains `position_ms`. `docs/spec.md`
   section 5.6.1 describes it. `config :my_hi_fi, :pipeline` is a new test seam,
   because the pipeline of this firmware needs a sound card and a build server
   holds none.

   **The error of a variable bitrate resume is still to measure.** Section 10 holds
   it. An episode plays now, so the measurement is possible.
8. ~~Add the key to `MyHiFiWeb.SettingsLive`.~~ Done on 2026-08-23. The page holds
   the address of the signup page, it says whether the device holds a key, and it
   sends no secret back to a browser. A save asks the index whether the key works.
   Read in a browser as well as in tests.
9. ~~Add the refresh job, and the 200 episode limit.~~ Done on 2026-08-23. It also
   removes a show that no person subscribed to and that nothing has touched for a
   week, because two visits to the trending list wrote 201 rows. `MyHiFi.Podcast.Refresh`
   holds the read of one feed, so the job and the source cannot disagree. Run
   against a live 256 episode feed: it wrote 200.
10. ~~Play an episode on the board. Stop in the middle, and confirm the resume.~~
    Passed on 2026-08-24, at the fourth attempt. The place and the resume were
    correct from the first read; the sound was not, and it took four faults to fix.

    - **The audio broke, and no person could listen.**
      `MyHiFi.Player.HttpSource` holds no flow control on the read of the body, so a
      podcast server filled its queue and `trim/1` dropped the oldest 64 KB. The log
      of two plays of one 49.7 MB episode held **1259** such drops. The answer is a
      file: `MyHiFi.Player.Download` writes it and `MyHiFi.Player.FileSource` reads
      it. See `docs/episode-download-plan.md`.
    - **The stop gave up before its own work ended.** `MyHiFi.Player.stop/0` used the
      default `GenServer.call` timeout of 5 seconds, and `stop_pipeline/1` waited up
      to 5 seconds by itself. The player now stops the sound, answers, and takes the
      pipeline down in `handle_continue/2`. A stop measured 75 ms after that.
    - **The reader gave the decoder the whole file in one buffer.**
      `Membrane.MP3.MAD.Decoder` decodes a whole input buffer in one callback, so
      that asked it for 822 MB of samples on a board that holds 363.9 MB. The board
      raised its memory alarm and a person heard noise. `MyHiFi.Player.FileSource`
      now gives 16 KB at a time and asks for another turn.
    - **44100 Hz is rough on this board.** This one was not a fault of the podcast
      work: it was there for every 44100 Hz stream, and both RNZ streams hold 24000
      Hz so radio never showed it. A 440 Hz tone straight to `aplay` found it, and
      `rate48` of `/etc/asound.conf` holds the card at 48000 Hz. See section 17 of
      the specification.

    The resume steps over a second or two of audio, because the pipeline holds that
    much lead over the sound. Section 17 of the specification holds the numbers, and
    an exact resume needs the true map from a time to a byte.

11. ~~Measure the memory during a refresh, and record it in section 17 of the
    specification.~~ Done on 2026-08-24. A refresh of 13 subscribed feeds, and a
    first read of 12 of them, took 47.4 s and read every one. The BEAM held 111.8 MB
    before, 123.5 MB at the peak and 108.6 MB after, and the memory available never
    went under 146.4 MB. A refresh is therefore not a risk.

## 12. Changes to the specification

`docs/spec.md` changes in the same commit as the code:

- Section 3 removes podcasts from the excluded list, and it adds them to the
  included list.
- Section 5.1 gains `favourite?` on the `container` type, and `store_position/2`.
- Section 6 gains a line for the HTTP MP3 path of an episode, and the m4a count.
- Section 7 gains the `MyHiFi.Podcast` domain, and the refresh job.
- A new section describes the podcast source, in the shape of section 8 for the
  station data.
- Section 9 already describes a resume of a track with a position. Confirm that it
  agrees with section 8 of this plan.
- Section 15 gains the rows of section 10 of this plan.
- Section 17 gains the measurements of 2026-08-23.
