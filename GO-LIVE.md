# Going live

What this SDK still needs before it serves real ads, ordered by what actually
blocks the road rather than by how hard it is. Every item names where it lives,
and the ones already closed are struck through with the commit that closed them —
a list that only grows is a list nobody reads twice.

State: `swift test` passes 294 tests with no warnings, and CI builds `VASTKit`
for iOS, tvOS and macOS plus all three demos on every platform they claim.

## Blockers

**1. ~~An ad cannot be paused.~~** `pause()`/`resume()` report §3.14.1's player
operation metrics, the stall watchdog knows a paused ad is not a dead one, and
`.paused` finally means something. `resumeIfNeeded()` used to undo a host's pause
within one tick, because it could not tell that apart from the system stopping
playback after backgrounding. A pause also ends with its creative now: an ad
skipped while paused handed its pause to the next one, which then never restarted
after the app came back.

**2. ~~Host-reportable tracking was unreachable.~~** `report(_:)` is public, so
`mute`, `fullscreen`, `close` and the rest can be sent; and `loaded` fires from
`creativeDidLoad()`, which is the only place that knows the creative is ready.

**3. ~~Beacon delivery was unreliable.~~** `VASTBeaconQueue` persists what fails
and retries it on a later flush, including after a relaunch; a flush holds a
background task, which is where beacons went missing most — the end of a break is
when a viewer puts the phone down. A 5xx is retried and a 4xx is not. Retries are
rationed — one batch of at most 50 every 30 seconds per process, five tries per
beacon — and a retry keeps the time it was first recorded, so it still ages out.
Before that, a tracker that never answers, which is what an ad blocker makes of
every tracker it knows, had the whole backlog sent again with every new beacon.

**4. ~~No privacy manifest.~~** `PrivacyInfo.xcprivacy` states what the SDK does
with data — nothing of its own — and names the line to watch: the moment an
identifier is supplied, `NSPrivacyTracking` becomes true and the ad server's
hosts get listed under `NSPrivacyTrackingDomains`.

## Blockers only for programmatic demand

Skip this section while the inventory is direct-sold.

**5. ~~Macros went out almost empty.~~** Everything the session knew is answered:
`APPBUNDLE`, `PLAYERSIZE` from the ad surface, `MEDIAMIME`, `TRANSACTIONID` per
break, `SERVERSIDE`, `ADTYPE`, `CLIENTUA`, `VASTVERSIONS`, and `APIFRAMEWORKS`
only when something will really run OMID. `VASTMacroValues` carries what only a
host can supply — identifier, consent, where the break sits — and reports `-1`
when it is empty, which is honest and also often unbiddable.

**6. ~~VAST 4 required and monetisation elements were not parsed.~~**
`AdServingId`, `UniversalAdId`, `ViewableImpression`, `Icon`, `CustomClick`,
`Advertiser`, `Pricing`, `Category` and `Expires` all reach the host now. With no
viewability measurement the engine reports `<ViewUndetermined>`, which is the one
outcome of the three this player can honestly claim.

**7. No Open Measurement adapter.** `iVASTAdMeasurement` is the right seam and it
is deliberately empty, so every vendor currently hears `verificationNotExecuted`.
That is the honest answer and it is also incompatible with selling against a
viewability contract. The longest lead time on this list, and the only item here
that is not a programming problem: it needs the IAB OM SDK licence first.

## Important, not blocking

**8. ~~`load(xml:)` dropped a Wrapper's trackers.~~** It started a fresh chain for
the tail, losing that document's own `<Impression>` and `<Error>` URIs, restarting
the depth count so the real limit was twice `maxWrapperDepth`, and forgetting its
`allowMultipleAds`.

**9. ~~`configuration.clock` was dead API, and the largest test gap.~~** It is
honoured, and `VASTPlaybackLoopTests` drives whole breaks from a scripted tick
source — the layer that decides impressions at runtime had no test at all.

**10. ~~Media selection ignored the scheme.~~** `https` is preferred, so a
response offering both renditions cannot have the `http` one chosen on merit and
then fail under App Transport Security.

**11. ~~Nothing was localised.~~** `en` and `hy` ship with the package and follow
the device, so a host that configures nothing does not get an English skip control
in a non-English app.

**12. ~~Creatives were not preloaded.~~** The next asset is warmed while the
current one plays. Not prebuffering — an `AVPlayerItem` does not buffer until it
belongs to a player — but the DNS, the handshake and the container header, which
is what the readiness wait was spending.

**13. ~~The completion threshold truncated every creative.~~** It cut a fraction
of the running time rather than a tick: at 0.97 a thirty-second ad stopped with
nearly a second unplayed, usually where the logo is. A 0.25s margin bounds the
loss whatever the duration, and a stall past the watched threshold now completes
rather than reporting 402 for the last few frames — to the host as well as to the
ad server. A stall short of it ends as the 402 it reported, not as 405.

**14. ~~No CI.~~** Five jobs, which is how long the tvOS demo build stayed broken:
nothing built it.

**15. ~~Three small things.~~** Media selection asks the ad surface rather than
the whole screen — an inline player was handed 4K renditions it could not show —
`print` became a `Logger`, and `load()` gained a total budget, because
`wrapperTimeout` bounds one hop and five in series is twenty-five seconds.

## Still open

Everything above is closed except item 7. What has come up since, unclosed:

- **The AdChoices icon is parsed but not drawn.** `ad.icons` carries it; nothing
  renders it. §3.15 expects a player to display one, and a response carrying
  `program="AdChoices"` means somebody upstream undertook to — under the EDAA
  self-regulatory programme or a demand partner's policy, not under statute. So it
  matters exactly when a partner starts sending icons and not before: a host either
  draws it from the model or the SDK grows a surface element that does.
- **tvOS cannot offer a surface click**, by construction: a transparent layer
  takes no focus. The SDK reports it and the demos opt out knowingly; a real tvOS
  host needs `clickPresentation = .host` and a focusable control of its own.
- **The Picture in Picture policy has not been run on a device.** The decision it
  turns on is covered by tests; the coordinator that carries it out cannot be, since
  `AVPictureInPictureController` does not exist in a test process. The two iOS demos
  now offer the window, so this is a matter of running them —
  `requiresLinearPlayback`, the delegate forwarding, and whether iOS keeps the
  window open across `replaceCurrentItem`, and whether a pause from the window's
  own button arrives as the `timeControlStatus` change the session now reports on,
  are all still reasoned rather than observed. `registerPlaybackControls` joins
  the list: that the host's scrubber, speed menu and — under `.suspended` — its
  `allowsPictureInPicturePlayback` are taken for the break and given back exactly
  as they were is covered by tests against a real `AVPlayerView`, but nobody has
  watched it happen on a screen. The same goes for the Now Playing
  transport that came with it: the borrowing and giving back is covered by tests,
  because `MPRemoteCommandCenter` is real in a test process, but whether the lock
  screen actually loses its scrubber for the break has only been reasoned. The
  Simulator will answer neither: Picture in Picture needs a device.
- **The tvOS player is not 16:9.** The aspect ratio yields rather than fighting
  the column, because 16:9 wants 1012pt of a 1080pt screen and the rest of the
  screen cannot spare it. It degrades instead of breaking, which is not the same
  as being right.

## Order

Item 7 is the only blocker left, and its critical path is a licence rather than a
commit. The three open items above are each a day's work and none of them stops a
direct-sold break from playing today.

Scope note: this list assumes "live" means serving real ads in a host app. While
the inventory stays direct-sold, section two defers entirely.
