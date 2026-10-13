//
//  VASTVersion.swift
//  VASTSDK
//

import Foundation

/// This SDK's own version.
///
/// Hard-coded rather than read from a bundle: `VASTCore` ships without resources,
/// and a version that reads as "unknown" in a release build is worse than one
/// that has to be edited at release time. It reaches ad servers through
/// `[CLIENTUA]`, which is how an exchange tells one player from another when a
/// creative misbehaves.
///
/// The edit was missed twice — 1.3.0 and 1.4.0 said 1.2.0, and 1.6.0 through
/// 1.8.1 said 1.5.0 — so CI now fails a `vX.Y.Z` tag build when the tag and
/// this value disagree.
public enum VASTVersion {
    public static let current = "1.8.1"
}
