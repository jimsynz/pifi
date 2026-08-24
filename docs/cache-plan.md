# Plan: one cache on disk, for any part of the firmware

- Date: 2026-08-23
- Status: every step is done. Step 7 was measured on the board on 2026-08-24.
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

`MyHiFi.Artwork` is a cache that holds one kind of thing. This plan makes it a
cache that holds any kind of thing, and it gives artwork the place of a caller.

Section 13 of `docs/spec.md` already asks for this. It says the cache holds two
types of data, artwork now and downloads later, and the code holds one. This work
makes the code say what the specification says.

Three things change with it:

- The limit stops at 64 MB today, and the partition holds 13.5 GB free.
- The oldest file goes first. A person wants the least used file to go first.
- `MyHiFi.Podcast` needs the cache for artwork of a show and of an episode, and a
  later version needs it for a whole episode.

## 2. Decisions

| Question | Decision |
|---|---|
| What holds the model? | `ash_storage`. |
| What is the key of an entry? | A namespace and a key that the caller gives. |
| How does an entry leave? | Least recently used, by a time in the database. |
| How large does the cache grow? | To the free space of the partition, less a reserve. |
| Who says what a file may hold? | The caller, and not the cache. |
| When do transformations arrive? | Later, behind a behaviour, and driven by a program. |

## 3. `ash_storage`

See <https://github.com/ash-project/ash_storage>. It holds a blob resource for the
data about a file, an attachment resource that joins a blob to a record, and a host
resource that declares an attachment. `AshStorage.Service.Disk` writes to a local
partition, and the transformations are optional, so this needs no native code.

The blob resource is what earns it: the key, the size, the sum, the purge that removes
the file and the row together, the variants, and the disk service. **The attachment
layer does not fit, and section 6.1 says why.**

**It is not on Hex.** Its author says that it is not quite releasable and that the
API iterates. This firmware therefore names a git reference and pins it, in the way
that `vintage_net_wizard` is pinned. Read section 8 before you accept that.

## 4. The model

`MyHiFi.Cache` is the front of it, and it holds no knowledge of any caller.

    MyHiFi.Cache.put(namespace, key, %{bytes: bytes})
    MyHiFi.Cache.put_from_url(namespace, %{url: url})
    MyHiFi.Cache.fetch(namespace, key)
    MyHiFi.Cache.touch(entry)
    MyHiFi.Cache.keep(entry)
    MyHiFi.Cache.purge(entry)
    MyHiFi.Cache.purge_all(query)
    MyHiFi.Cache.prune()

`put_from_url` reads an address and holds what it gives, and the key becomes the hash
of the address when a caller names none. It sets `content_type` from the header and it
reads no byte of the body to check that, because a header is often wrong and a caller
that needs to know looks itself.

`purge_all` takes a query and removes every entry that it names in one bulk destroy.
**`strategy: :stream` is not optional there**: `purge_blob` deletes the file in a
`before_action` hook, and a strategy that wrote the rows in one statement would leave
every file on the disk. A test proves that the files go.

A namespace is an atom, such as `:artwork` or `:download`. A key is a string that
the caller makes, and the caller decides what it means: artwork uses a hash of the
address, and a download uses the identifier of an episode.

The name of a file on disk stays a hash, so no text from a service reaches the file
system. That rule holds today and it does not change.

### 4.1 What artwork became, on 2026-08-23

`MyHiFi.Artwork` keeps its own name and loses the cache. It holds what a cache
cannot know:

- The four image types that this firmware serves, and the reason that SVG is
  absent. An SVG file holds a script, and the device serves each file from its own
  address, so such a script would run with the rights of the web interface.
- The read of the first bytes of a body, because the `content-type` header lies.
- The 4 MB limit for one image.

It then calls `MyHiFi.Cache.put(:artwork, hash, ...)`.

This split is the point. A generic cache must not decide what is safe to serve.

**The name of an entry lost its extension.** It was `<hash>.png`, and the module tried
each of four extensions against the disk to learn whether it held an address. The type
now lives on the row, so a name is the hash alone and one read answers. The route
therefore serves `/artwork/<hash>`.

`serve/1` replaces `path/1` and `content_type/1`. It reads one row, it refuses a type
that this route does not send, and it notes the use for the eviction. Three reads
became one, and the note had nowhere else to live.

### 4.2 The two callers

`MyHiFi.Player` asks for a name and puts an address in the queue of
`MyHiFi.Artwork.Worker`, and it did not change at all. `MyHiFiWeb.ArtworkController`
now calls `serve/1` in place of two functions. Nothing outside `MyHiFi.Artwork` learns
about the cache.

## 5. Least recently used

**The file system cannot answer this.** Nerves mounts ext4 with `relatime`, so
`atime` moves only when it is older than `mtime` or a day old. A cache that reads
`atime` would evict a file that a person used an hour ago.

The blob therefore holds `last_accessed_at`, and the cache writes it when a caller
reads the entry. `MyHiFiWeb.ArtworkController` serves a file, so that is where the
write happens for artwork.

One write for each read of an image is a cost. A page that shows 40 covers writes
40 rows. Two answers, and the plan takes the first one:

1. Write it, and accept the cost. SQLite on this board writes a row in under a
   millisecond, and the artwork route already holds a cache header of one week, so a
   browser asks once.
2. Hold the times in memory and write them each minute. This needs a process and it
   loses the last minute at a restart.

## 6. How large

The rule today is a twentieth of the free space, up to 64 MB. The cap binds, and
it was chosen when 247 station logos meant 5 MB. A podcast cover is 1.2 MB.

The new rule: **the free space of the partition, less a reserve of 1 GB.**

A fixed reserve and not a share, because the reserve protects the database and the
room for a download. A share of a large partition gives a reserve that grows for no
reason, and a share of a small one gives a reserve that is too small to matter.

### 6.1 The join, and why it is ours and not the one of `ash_storage`

`MyHiFi.Cache.Attachment` joins an entry to a record. A host declares its own side and
filters for its own type, so the cache holds no column that names a resource and no
knowledge of the parts of the firmware that use it.

**The attachments of `ash_storage` cannot do this.**
`AshStorage.Operations.attach/4` "uploads the file, creates a blob record, creates an
attachment record". It creates a blob each time, and it holds no way to attach one
that exists, so two records that share a picture would hold two blobs and two files.

A read on 2026-08-23 shows what the join gives instead. One cover of 1.2 MB, named by a
show and by each of its 30 episodes:

| | Through this join | Through the attachments of the package |
|---|---|---|
| Entries | 1 | 31 |
| Files on disk | 1 | 31 |
| Bytes on disk | 1.2 MB | 37.2 MB |

### 6.2 The aggregates are queries, and not fields

**`AshSqlite` answers `false` for `{:aggregate_relationship, _}`.** A `count` or a `sum`
declared on a resource therefore cannot compile against this data layer, whatever the
shape of the relationship. That is worth knowing, because the aggregates were the
reason to take this package.

It answers `true` for `{:query_aggregate, _}` and for `{:filter_relationship, _}`, so
the same numbers come from a query. `MyHiFi.Cache.usage_of/2` gives the count and the
bytes that one record holds, and it reads `exists(attachments, ...)`.

### 6.3 What the eviction does to a join

An eviction takes an entry that records still name, and it takes the join rows with it.
The key holds `ON DELETE CASCADE`. A record that named the file keeps the address that
it came from, so the next read fetches it again.

The other answer would let a record hold a file against every eviction, and a cache
would then fill with entries that nothing may remove. `keep?` is the mark for a file
that must stay, and a record naming a picture is not that.

**A record that goes takes its own rows**, since 2026-08-23.
`MyHiFi.Cache.Attachment.Changes.DetachRecord` carries the type, and each host puts it
on its destroy action. The join holds no key to the record, so the database cannot do
this and only the host knows its own type. `Show` and `Episode` carry it, and a station
will when something attaches a logo.

**It stops at the join rows, and it does not reach the entries.** Two reasons, and the
first one is a fault and not a preference.

An entry is shared. One cover serves a show and each of its 30 episodes, so taking the
entries of a show would take a picture that 30 surviving episodes still name. A test
holds that case with two shows and one picture.

And nothing needs it. A cache reclaims by least recently used, and an entry that no
record names any more is the coldest thing in it, so the eviction takes it exactly when
the room is wanted. Reference counting would also have to tell an entry that lost its
last reader from an entry that never had one, and the second is ordinary: nothing
attaches artwork today, and every entry of the cache has no reference at all.

The change is not atomic, because it reads and writes another table, so each destroy
names `require_atomic? false`.

## 7. The problem that one cache brings

A single list of least recently used entries holds a fault, and this plan must not
ship without an answer to it.

An episode of a podcast is 60 MB. Artwork is 1.2 MB. If both live in one list, then
one download evicts 50 covers, and a person who moves through a long list of shows
evicts the episode that they are in the middle of.

**An entry therefore holds `evictable?`, and the caller sets it.** Artwork is always
evictable. A download of an episode that holds a place is not, until the person
finishes it or removes it.

This is simpler than a budget for each namespace, and it puts the choice with the
caller that knows. A cache that is full of entries that it may not evict gives
`{:error, :no_room}`, and the caller then decides.

## 8. Risks and unknowns

| Item | Risk | Action |
|---|---|---|
| `ash_storage` is not released | The API iterates, and this firmware would hold a git reference to a moving target. A breaking change arrives with a `mix deps.update`. | Pin a reference, as `vintage_net_wizard` is pinned. Read the change list before each move. Accept that this is the largest risk of this plan. |
| Three resources | The data model holds five resources today, and this adds three for a cache of pictures. | Measure the migration and the compile time. Keep `MyHiFi.Cache` as the only door, so the resources stay behind it and a later change of mind costs one module. |
| Serving any type from `'self'` | A generic cache holds any bytes. A generic route that served them would give stored XSS on the origin of the device. | The route stays the route of artwork, and it serves the four image types only. A namespace that needs a route of its own gets one, with its own list of types. `@sobelow_skip ["XSS.ContentType"]` stays true only while that holds. |
| ~~A write for each read~~ | Measured on 2026-08-24. The write is 11.82 ms and not the "under a millisecond" of section 5, so a page of 40 covers needs about 0.5 s. | The first answer stays, because the route holds a cache header of one week and a browser therefore asks once. See step 7. |
| The reserve | 1 GB is a guess. A download of a long episode is 200 MB. | Measure after downloads arrive. |
| Transformations | The near future needs a thumbnail of 320 pixels for the screen, and `vix` cannot cross-compile. | Section 9. |

## 9. Transformations, later

The model holds room for them now, and the code holds none.

A blob holds derivatives. A derivative names its parent, and it holds its own size
and its own `last_accessed_at`, so the cache evicts a thumbnail and keeps the
original, or the reverse.

The step that makes one sits behind a behaviour, and the first implementation makes
nothing. **It will not be a NIF.** `MyHiFi.Player.PortDecoder` holds the reason that
this board already accepts: "a program needs no NIF, no Bundlex target variables,
and no precompiled archive". `vix` breaks each of those, and it cannot cross-compile
at all, because it loads its own NIF while it compiles and a build machine is
x86_64.

The likely program is `djpeg` of libjpeg-turbo, through NBPR. `djpeg -scale 1/8`
scales inside the DCT, so it is cheap, and a screen of 320 by 240 wants exactly that
from a source of 3000 by 3000. libjpeg-turbo is about 1 MB, where libvips is 17 MB,
and this project already refused 17 MB for portaudio.

## 10. Order of work

1. Add `ash_storage` as a pinned git reference. Confirm that it compiles for
   `myhifi_rpi0_2`, and that its disk service needs no native code.
2. Build the blob and the attachment resources, and the migration.
3. Build `MyHiFi.Cache`, with the namespace, the key, `last_accessed_at`, and
   `evictable?`.
4. Move `MyHiFi.Artwork` onto it, and keep its public functions as they are. The
   old files may go: the cache refetches an image that it does not hold.
5. Change the size rule to the free space less 1 GB, and the eviction to least
   recently used.
6. ~~Join an entry to a record.~~ Done on 2026-08-23, with a join of ours and not the
   attachments of `ash_storage`. `MyHiFi.Podcast.Show` declares its side. See sections
   6.1 to 6.3.
7. ~~Measure: the write for each read, the time of a migration on the board, and the
   memory.~~ Done on 2026-08-24. Section 17 of `docs/spec.md` holds each number.

   **The write costs 11.82 ms, and section 5 of this plan named "under a
   millisecond".** Plain SQL writes the same row in 2.21 ms, so the Ash action holds
   9.6 ms of it. A whole `MyHiFi.Artwork.serve/1` is 26.06 ms in series, and 33 of
   them, 8 at a time, took 438 ms. A page of 40 covers therefore needs about 0.5 s of
   database work.

   **The plan keeps its first answer, and for another reason.** The route sends a
   cache header of one week, so a browser asks once for each picture. The cost falls
   on a first view alone, and a write behind a process would save 0.5 s once a week
   and lose the last minute at each restart. Change this only if the device screen
   reads the cache often, because that reader holds no browser cache.

   The 5 migrations against an empty database took 704 ms and 902 ms in two runs, so
   a first boot pays under a second. A scratch database on `/root` gave those
   numbers, and the real one was not touched.
8. ~~Change section 13 of `docs/spec.md`, and section 17 for the measurements.~~ Done
   on 2026-08-23.

## 11. Decisions of James

1. **The branch is `podcasts`.** The podcast work is what breaks the cache as it
   stands: a station logo is 3.7 KB to 46 KB, and a podcast cover is 1.2 MB against
   a limit of 64 MB. The fix therefore belongs with the change that needs it, and
   not in a branch of its own.
2. **`ash_storage`, and transformations in the near future.** Section 8 holds the
   risk of a package that is not released, and section 9 holds the way that a
   transformation reaches this board. The note stays with the work so that the
   reason stays readable.
3. **The reserve is 1 GB**, until a measurement says another number. Section 6 holds
   the reasoning.
