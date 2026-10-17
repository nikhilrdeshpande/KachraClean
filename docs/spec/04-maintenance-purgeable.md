# Maintenance tasks and purgeable space

Source: the reference app's performance review screen (accessibility tree + screenshot) and our own
measurement with public Apple APIs on the same Mac, minutes apart.

## Observed (reference app)
Smart scan proposed two pre-selected maintenance tasks:
1. Flush the DNS cache.
2. Free up purgeable space, with an estimate of up to 2.7 GB.
(Other performance features — login items, background items — exist as separate modules but produced
no smart-scan task on this Mac.)

## Our measurement (public API, no private frameworks)
`URLResourceValues` on the home volume:

| Key | Value |
|---|---|
| `volumeAvailableCapacity` (free blocks) | 34.34 GB |
| `volumeAvailableCapacityForImportantUsage` | 37.09 GB |
| `volumeAvailableCapacityForOpportunisticUsage` | 21.99 GB |
| important − free | **2.74 GB** |

`important − free` matches the reference app's 2.7 GB estimate. **Inferred:** the purgeable estimate is
this public-API difference. Local Time Machine snapshots: none on this Mac, so snapshots are not part
of this figure here.

## KachraClean design
- Show purgeable space as `importantUsage − available`, labelled honestly as "macOS can free this on
  demand"; it is not junk the user owns.
- How to actually *trigger* purging (the reference app does it as a task) is an open question for the
  macOS-internals study (`CacheDelete` / `deleted` daemon). Candidate public approach: briefly request
  space (e.g. create and delete a large sparse/preallocated file) so macOS purges on demand; must be
  measured before shipping. Never shell out to private tools.
- DNS flush: `dscacheutil -flushcache` + `killall -HUP mDNSResponder` (needs admin) — a maintenance
  extra, not a storage feature; out of v1 scope.

## Side note from the same session
Free space dropped ~19 GiB during the day; investigation showed it came from the user's own ML work
(model hub blobs, local diffusion-model weights, a VM disk image), reinforcing that model caches are a
first-class cleanup category for developer Macs.
