# VASTSDK

A native VAST 4.3 linear-video ad SDK for iOS, tvOS and macOS. No Google IMA, no
VPAID, no WebView.

4.3 is what it implements; 2.0, 3.0 and every 4.x **parse through the same
version-tolerant path**, because real ad servers still send them. An element this
SDK does not know is skipped rather than rejected, and the only document it
refuses outright is a pre-3.0 one — whose root is not `<VAST>` at all — which
gets VAST error 102 `versionNotSupported`, the code the specification reserves
for it. What an older tag does not get is whatever the table below marks `❌`,
VPAID first among them.

```swift
.package(url: "https://github.com/KhorenAs/VastSDK-apple.git", from: "1.0.0")
```

Then depend on `VASTKit` (player and ad UI) or on `VASTCore` alone — parsing,
wrapper chains, pod scheduling and tracking, with no player at all.

```
Sources/
  VASTCore/   pure logic — does not import AVFoundation or SwiftUI
  VASTKit/    player + UI binding
  Harness/    runnable logic harness: `swift run Harness`
Examples/     VASTDemo.xcodeproj — SwiftUIDemo · UIKitDemo · AppKitDemo
Tests/        279 tests
```

Android and Web get their own repositories rather than empty folders here. The
three share the specification, the test fixtures and the behavioural decisions —
not code, and not a checkout: an Apple host has no use for Kotlin, and cloning a
dependency brings the whole repository with it.

[GO-LIVE.md](GO-LIVE.md) lists what this SDK still needs before it serves real
ads, ordered by what blocks the road rather than by effort.

## Using it

```swift
let session = VASTAdSession(player: myPlayer)

try await session.load(tag: adTagURL)   // follows Wrapper chains
await session.play()                    // plays the pod, reports tracking
```

SwiftUI hosts compose the ad UI over their player:

```swift
ZStack {
    MyPlayerView(player: player)
    VASTAdSurface(session: session)
}
```

UIKit and AppKit hosts hand the SDK a container instead:

```swift
session.attach(to: playerOverlayView)
```

Every element of the surface is replaceable — `vastSkipButton`, `vastAdBadge`,
`vastCountdown`, `vastClickThrough` — so the SDK owns the *behaviour* the spec
requires while the host owns the look. A replaced skip control is still wrapped
in a `Button`, so it stays focusable and hittable on every platform, and its
drawn size is checked: a builder that returns nothing is reported rather than
silently leaving a skippable ad unskippable.

On tvOS there is no pointer, so `clickPresentation = .surface` cannot work — a
transparent layer takes no focus. The session says so through the delegate
instead of drawing something inert; a tvOS host uses `.host` with a focusable
control of its own, or `.disabled`.

### Knowing what was reported

Tracking is the one thing a host cannot observe for itself: the beacons live
inside the response and go out from the session, so an embedder has no way to
know an ad reached its midpoint. The delegate says so.

```swift
func session(_ session: VASTAdSession, didReport event: VASTBeacon.Kind, for ad: VASTAd?)
```

Called once per distinct kind, in the order the beacons went out, and whether or
not the network accepted them — what is reported is the event, not the delivery.
A response carrying three `<Impression>` URLs is three beacons and one
impression, so it fires once for that.

It is driven from the same funnel as measurement, for the same reason: a second
set of call sites would drift from the beacons, and then a host's own analytics
would disagree with the ad server's. Reporting stays the session's job — this is
a mirror, not a hook, and nothing is asked of the delegate.

### The player's own controls

An ad the viewer can scrub is an ad the viewer can get past. Nothing is
mis-measured when they do — a forward seek never extends the tracking engine's
coverage of the creative, and reaching the end that way is not completion — but
the viewer still leaves the ad behind, and the advertiser still paid for the
impression they were shown. VAST defines no attribute that would permit seeking
inside a linear creative. The only reason it is possible is that the controls
belong to the host.

Hand them over and the break borrows them:

```swift
session.registerPlaybackControls(playerViewController)  // AVPlayerView on macOS
```

- On iOS and tvOS it sets `requiresLinearPlayback`, which removes scrubbing, fast
  forward and forward skip, and empties `speeds`. Play and pause are not on that
  list and stay — a paused ad is reported as a §3.14.1 `pause` rather than fought
  — while the speed menu goes for the same reason `NowPlayingPolicy.describesAd`
  locks `changePlaybackRateCommand`: watched time is measured from the playhead,
  so a creative played at 2× is watched in half the time and every quartile still
  fires.
- On macOS it sets `controlsStyle` to `.none`. `AVPlayerView` has no
  `requiresLinearPlayback`, no delegate method that can refuse a seek, and no
  documentation of what the `.minimal` pane contains, so the pane that certainly
  carries no timeline is the only honest answer. It costs the viewer play and
  pause for the length of the break, which is the one place this is blunter than
  it wants to be.

- Under `.suspended` only, it also switches off `allowsPictureInPicturePlayback`.
  That is the one Picture in Picture lever an AVKit host has: AVKit builds and
  keeps its own `AVPictureInPictureController`, so `registerPictureInPicture` has
  nothing to be given, and this switch — `true` by default on iOS and tvOS — is
  all that is exposed. In one respect it is better than the controller's route,
  because it refuses a start instead of closing a window a moment after it
  opened.

  It is also less: neither `AVPlayerViewController` nor `AVPlayerView` will say
  whether the window is already open, and what revoking the permission does to
  one that is is undocumented. So for an AVKit host `.suspended` means "no window
  opens during the break" rather than "no window exists during it", and
  `.pausesAd` — which has to know when the window opens — cannot be honoured at
  all. Both need a host that owns its `AVPlayerLayer` and registers a controller.

Every value is saved before it is changed and restored from what was saved, not
from a default: a host that already required linear playback for its own content
— a live stream, a player that never allowed scrubbing — does not get scrubbing
handed to it as a parting gift, and a host that never allowed the window does not
find it allowed when the break ends. Call `unregisterPlaybackControls()` if the
player outlives the session.

There is no policy to choose here, unlike the window and the system transport.
Registering *is* the opt-in. A host drawing its own controls — a custom bar, or a
SwiftUI overlay — never registers anything and binds to `permitsPlaybackControls`
instead, which is the same answer in the shape a view can read. The SDK cannot do
that half itself: the switch lives on a view controller an ad session never sees,
and Apple's own header says so — "This method should not be used to disable
scrubbing; use the `requiresLinearPlayback` property of the AVPlayerViewController
instead."

### Picture in Picture

Picture in Picture is bound to the `AVPlayerLayer`, not to the item on it, so a
host that supports it at all shows the creative in the window without anyone
deciding to — and the surface, being views in the app, stays behind. Whatever a
player wants to happen there, it has to say so: `VASTSurfacePresence` cannot see
this one, because the surface is still present and still full size, just no
longer where the ad is.

Hand the session the controller and it applies a policy for the length of a
break, and only for that long:

```swift
let pip = AVPictureInPictureController(playerLayer: playerLayer)
session.registerPictureInPicture(pip)
```

- `.allowed` — the default — plays the ad in the window, like the content it
  interrupted. A viewer who opened the window asked for it, and what it costs is
  smaller than it first looks: tapping the window comes back to the app, where the
  surface is where it always was. The skip control is a tap further away rather
  than gone, and `skipControlUnavailableFor` says so at the one moment it matters
  — the offset elapsing with the viewer still out there.
- `.pausesAd` keeps the window and holds the ad while it is open, reported as a
  §3.14.1 `pause`. Nothing plays unwatched.
- `.suspended` closes the window for the break and switches off automatic entry
  while it runs: the ad plays where its controls are or it does not play.

The session takes the controller's delegate seat and forwards every callback to
whichever delegate was already there, so registering costs the host nothing; call
`unregisterPictureInPicture()` if the player outlives the session.

AVKit cannot refuse a start — `canStartPictureInPictureAutomaticallyFromInline`
covers automatic entry only, and the delegate's `willStart` cannot cancel — so
under `.suspended` a control left enabled opens the window and has it closed
again a moment later: right, and visibly clumsy. Bind your own control to
`session.permitsPictureInPicture` and it disappears for the length of the break
instead. Under the other two policies it stays true, because there the window is
the viewer's.

The window draws its own controls and AVKit exposes exactly one switch over them:
`requiresLinearPlayback`, which the break sets, and which disables fast forward,
forward skip and scrubbing. Play and pause are not on that list and cannot be
removed, so under `.allowed` and `.pausesAd` the viewer can pause an ad from the
window. That is reported rather than fought — `pause` and `resume` go out, and
`state` follows. A host that needs an unpausable ad wants `.suspended`.

None of it runs without the `audio` background mode and an active `.playback`
audio session — the window does not open at all otherwise.

### The system transport

Those same two settings make the app the Now Playing app, so Control Centre, the
lock screen, AirPods and CarPlay start offering a transport for whatever is on
the player. During a break that is the creative, and their seek controls are the
window's scrubber again — in a place the host cannot see it being offered.

There is nothing to register: `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`
are process-wide singletons. The break borrows them and gives them back, the way
it already borrows the host's player item.

- `.describesAd` — the default — disables the commands that would seek, skip or
  change rate, and publishes the ad's `<AdTitle>` and `<Advertiser>` while it
  plays. Both are restored when the break ends, `isEnabled` value by `isEnabled`
  value: a command the host had switched off comes back switched off.
- `.locksControls` does the first half and leaves the host's Now Playing
  information alone.
- `.untouched` does neither.

Play and pause are deliberately left enabled. They reach the `AVPlayer` like any
other pause, and the session reports them as §3.14.1 `pause` and `resume`.

`changePlaybackRateCommand` is locked with the seek controls, for a less obvious
reason: watched time is measured from the playhead, so a creative played at 2× is
watched in half the time and every quartile still fires.

## What it covers

| | |
|---|---|
| VAST 2.0 · 3.0 · 4.0–4.3 documents | ✅ one version-tolerant parser — a pre-3.0 root gets error 102 |
| Linear ads | ✅ |
| Skippable Linear (`skipoffset`) | ✅ |
| Ad Pods (`sequence`) + stand-alone substitution | ✅ |
| Wrapper chains (depth ≤ 5, tracker accumulation, error fan-out) | ✅ |
| Tracking: impression, quartiles, progress offsets, skip, click, error | ✅ |
| VAST 2.0/3.0 legacy event names | ✅ |
| Pause and resume, reported as player operation metrics | ✅ |
| §6 macros — everything the session knows, plus `VASTMacroValues` for what only you do | ✅ |
| `<Extensions>` handed to the host raw | ✅ |
| `<AdVerifications>` parsed and handed over — VAST 3 and 4 shapes | ✅ |
| `<UniversalAdId>` · `<AdServingId>` · `<Advertiser>` · `<Pricing>` · `<Category>` · `<Expires>` | ✅ |
| `<CustomClick>`, kept apart from `<ClickTracking>` | ✅ |
| `<ViewableImpression>` | ✅ parsed — and `<ViewUndetermined>` is what this player can honestly send |
| `<Icon>` (AdChoices) | ✅ parsed into `ad.icons` — ❌ not drawn; see below |
| Undelivered beacons kept and retried, across launches | ✅ |
| The host's own transport controls held linear for the break, and given back | ✅ |
| Picture in Picture policy for an AVKit host | ✅ `.suspended` refuses a start — the rest needs your own `AVPlayerLayer` |
| Skip control and countdown localised (`en`, `hy`) | ✅ |
| Executing verification code (OM SDK) | ❌ by decision — `iVASTAdMeasurement` is the seam |
| NonLinear · Companion · VPAID · SIMID | ❌ by decision |
| VMAP (ad-break scheduling) | ❌ out of scope |

Ignored elements are skipped, not rejected — an unknown element never fails a
response. A response whose *only* creative is one of these is a different case:
the slot was filled, so the server hears VAST error 201 ("expecting different
linearity") on its own `<Error>` URI rather than being told it returned nothing.

VMAP is out of scope rather than pending. It answers "when do breaks happen",
which is a question about the content timeline — the host's, or its ad server's.
This SDK answers "what plays in one break, and what is reported while it does".
A host with a VMAP document reads the break times from it and calls `load` and
`play` at each one; a host whose server already schedules breaks, as most
app-side ad servers do, never needs it at all.

## Four decisions worth knowing

**Compliance is enforced, not hoped for.** `SkipPresentation` says who provides
the skip control. Under `.unsupported`, a skippable ad is refused with VAST error
200 rather than played without one, because §2.3 forbids exactly that. The
default is `.sdk`, so a host that configures nothing is compliant.

**Verification is described, not executed.** `<AdVerifications>` is parsed —
including the VAST 3 shape, where vendors shipped it inside
`<Extension type="AdVerifications">` — and normalised into `ad.adVerifications`,
so a host cannot tell which version answered. Running that code means the IAB
Open Measurement SDK, which is licensed separately and stays outside this
package. `iVASTAdMeasurement` is the seam:

```swift
session.measurement = MyOpenMeasurementAdapter()
```

With nothing set, every vendor that asked is sent `verificationNotExecuted` —
reason 1 where no OMID resource exists, reason 3 where one does and nothing ran
it. With an adapter set the SDK goes quiet, drives the adapter from the same
beacons the ad server receives, and takes `resourceLoadError` back through
`reportVerificationNotExecuted(_:reason:)`, which only the loader can know.

`<ViewableImpression>` follows from the same rule. §3.6 offers three outcomes —
viewable, not viewable, undetermined — and a player with no viewability
measurement can honestly claim exactly one of them, so with nothing set the SDK
sends `<ViewUndetermined>`. Saying nothing at all is the tempting option and the
wrong one: an unmeasured impression left silent is counted as measured by whoever
asked. Note the other edge of that: **setting `measurement` makes the SDK go
quiet about viewability too**, on the assumption that your adapter is measuring
it. An adapter that does not leaves the vendor hearing nothing — neither a
measurement nor an admission that there was none.

What this costs in practice is narrow and worth stating plainly. Serving your own
inventory is unaffected. What you cannot do is satisfy a buyer whose contract
requires third-party accredited measurement, because the independence is the
product, not the number. That needs the OM SDK licence, and nothing in this
package substitutes for it.

`<Icon>` is the same shape of decision, one step further along: it is parsed into
`ad.icons` — program, position, offset, resource, click-through — and not drawn.
A host that draws its own ad UI already has everything it needs to render an
AdChoices mark from that. What the SDK will not do is fetch and place an image on
your behalf and leave you unable to tell whether it appeared.

Worth being exact about the obligation, because it is easy to overstate: §3.15
expects a player to display an icon, and an `<Icon program="AdChoices">` in a
response means somebody upstream undertook to show it — under the EDAA
self-regulatory programme, or under a demand partner's own policy. That is a
contract rather than a statute, and whose contract depends on who sent the icon.

**`.host` transfers the obligation, and nothing checks it.** Under
`skipPresentation = .host` or `clickPresentation = .host` the SDK draws no
control and makes no claim about whether you drew one. It cannot: it does not
know your view tree. That mode is a statement that §2.3 and §3.10.1 are yours to
honour — the SDK's own promises hold only for `.sdk` and `.surface`.

**The correctness-critical logic never touches AVPlayer.** `VASTCore` cannot
import AVFoundation — the compiler enforces it. Time arrives as `VASTTick`
values, and the tracking engine returns beacons instead of sending them. That is
why quartile behaviour, seek rejection, pod substitution and wrapper limits are
all testable with no player, no network and no waiting.

## Things that are easy to get wrong

Each of these is a bug that was found and is now pinned by a test.

- **Quartiles measure covered timeline, not accumulated deltas.** A stall does not
  skip any of the creative; a seek does. Summing playback deltas discounts stalls,
  so on a stuttering connection `complete` never fires and the ad hangs.
- **Tracking is never awaited from the playback loop.** One unreachable tracking
  host froze the countdown, the skip control and the end of the ad.
- **`AVPlayerItem.status` is polled, not observed.** If the item settles before an
  async `publisher(for:).values` sequence is subscribed, the transition is never
  delivered and the break stops with the creative never appearing.
- **`try? await Task.sleep` swallows cancellation.** A dismissed screen carried on
  into the break — audible, with nothing left to stop it.
- **`URL(string:)` percent-encodes brackets**, so `[ERRORCODE]` arrives as
  `%5BERRORCODE%5D`; and a leftover vendor macro makes Foundation re-encode the
  whole string, double-encoding values that were already correct.
- **Picture in Picture follows the layer, not the item.** Replacing the item swaps
  the creative into a window that is already open, so the ad appears there on its
  own — with the skip control and the click layer left behind in the app, and the
  surface probe reporting a surface that is present, full size and no longer where
  the ad is.
- **iOS never resumes playback after backgrounding.** `rate` is left at 0, and a
  stall watchdog that keys on `rate > 0` cannot tell that apart from a hang.
- **Recovering from that made pausing impossible.** Re-issuing playback every tick
  is indistinguishable, from `rate` alone, from a host deliberately pausing — so a
  pause was undone within one tick and reported to nobody. `timeControlStatus` is
  what separates them: `.waitingToPlayAtSpecifiedRate` is the buffer and `.paused`
  is somebody's decision, where a rate of zero is both. The SDK watches the status,
  so a pause made on the player — the Picture in Picture window's own button
  included — is honoured and reported as §3.14.1 `pause`. `pause()` is still the
  path a host should take; it is no longer the only one that works.
- **A host-supplied control cannot be handed back as-is.** `makeUIView` runs once
  per view identity, so returning the builder's view froze whatever the first call
  produced: a countdown that never counted, a skip control stuck on the hourglass
  it was born with. The container needs an intrinsic size too, or the control
  collapses to its minimum and its label is clipped away.
- **`UIControl` does not send `.primaryActionTriggered` from a tap.** Only
  `UIButton` does. A custom control registered for it works on tvOS, where the
  remote's select is raised by hand, and silently does nothing on iOS.
- **A fraction of the running time is the wrong thing to cut.** Ending the ad at
  97% of its duration lost nearly a second of a thirty-second creative and a third
  of that from a ten-second one. The gap that matters is one tick, so the margin is
  in seconds.
- **Rebuilding a value type drops what you forget to copy.** The Wrapper chain
  reconstructs the ad on its way out; every field added to `VASTAd` and not added
  there disappears for any response that came through a Wrapper — which is most of
  them, and invisible until a report comes back empty.

## Running things

```bash
swift build                 # VASTCore + VASTKit
swift test                  # 279 tests
swift run Harness           # tracking engine + parser against fixtures
```

```bash
open Examples/VASTDemo.xcodeproj
```

Then pick a scheme — SwiftUIDemo, UIKitDemo, AppKitDemo — and a destination.
The demo's scenario list covers two live tags from Google's public IMA sample
inventory, skippable and non-skippable responses, a three-ad pod, a no-fill
response and an unplayable creative. The list footer shows live player-screen
count; it must read zero once no player screen is open.

The iOS demos pick a Picture in Picture policy above the list — it is part of a
session's configuration, so it applies to the next player screen rather than to
the one already open — and each player screen has a `PiP` button. Backgrounding
the app mid-ad is the other way in, and the one worth watching. Both need a
device: the Simulator does not do Picture in Picture.

## Requirements

iOS 15.6 · tvOS 15.6 · macOS 13 · Swift 6 (strict concurrency)

The floor came down from 16 for a host that had shipped to 15.6 and could not
raise it. One feature is version-gated by it: `registerPlaybackControls` locks
the AVKit speed menu, and `speeds` arrived in iOS 16 and tvOS 16 — below that
there is no menu to lock, so nothing is missing rather than something being
skipped.

Test fixtures under `Tests/VASTCoreTests/Fixtures/` come from the IAB sample tags
shipped with [dailymotion/vast-client-js](https://github.com/dailymotion/vast-client-js)
(MIT), used because they carry the inconsistencies real ad servers produce. One is
a live AdFox response, kept because a real server's inconsistencies are not the
ones a spec-shaped fixture has.

The parser was written against the IAB VAST 4.0, 4.1 and 4.2 XSD schemas, which
are published by the IAB Tech Lab rather than vendored here. They used to be — and
`vast_4.3.xsd` turned out to contain the fourteen bytes `404: Not Found`, which is
what happens to a file no build ever reads.

## Releasing

Set `VASTVersion.current` in `Sources/VASTCore/VASTVersion.swift` to the new
version first, then tag the commit that carries it as an annotated `vX.Y.Z`. The
tag is what SwiftPM resolves; the constant is what an ad server hears through
`[CLIENTUA]`. CI fails a tag build where the two disagree, but only once the tag
has been pushed — the edit is what keeps a wrong version from shipping.

## License

MIT — see [LICENSE](LICENSE).

## 1.8.2: release version reporting

The SDK reports `1.8.2` through `VASTVersion.current` and VAST client macros.
Release tag CI checks that the declared version matches the tag. The Swift Package URL is `https://github.com/KhorenAs/VastSDK-apple.git`.
AVPlayer clock reads and host playback restoration run on the main actor on
iOS and tvOS; Now Playing test cleanup also respects its actor isolation.

## 1.8.1: conditional custom ad UI

With `session.isHiddenUi = true`, `UiHideable=1` (or `UiHidden=1`)
hands that creative's UI, including skip, to the host. Keep the default
`skipPresentation: .sdk`; creatives without the flag retain SDK controls.
Ownership follows each creative in a pod. Explicit `.host` and `.unsupported`
skip policies retain their existing meaning.
