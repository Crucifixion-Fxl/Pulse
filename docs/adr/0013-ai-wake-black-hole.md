# AI wake presentation

Status: accepted, visual invocation only.

Pulse's existing agent pane monitors coding sessions. The new wake presentation is an independent visual entry point: hold plain Space, hide quota/bot content, unfold by 14% (at most 64 points), and reveal a monochrome starfield inside the expanding opaque black surface. It does not capture microphone audio, infer listening state, or send a model request.

The keyboard layer waits 120 ms to distinguish ordinary typing from a hold. A further 700 ms completes the charge. Early release reverses the presentation; after activation, Escape or another Space hold closes it. Short spaces are replayed once to their original text/playback path. Modified shortcuts pass through. A consuming CGEvent tap is installed only when existing Accessibility permission permits it; a local event monitor and a menu preview remain available without global access. Permission is requested only by the explicit status-menu action.

Rendering uses an independent transparent panel with a fixed envelope and Core Animation layers. The black silhouette expands together with 72 small background stars and 40 deterministic infalling white particles. All particles are clipped inside the black silhouette; there are no colored halos, orbit lines or external effects. The height grows by 30 points to reveal depth below a physical notch. Opening and reversal interpolate from the current presentation-layer width. No particle or window layout loop runs per frame. Reduce Motion removes continuously repeating motion.

The normal island remains mounted, preserving page selection and editor drafts. Its presentation updates pause while the wake surface owns the display, then reconcile to the latest model state on dismissal. Screen changes, sleep and session resignation clean up the overlay and held-key state. An ordinary cancellation retains the held-key latch until key-up so key repeat cannot reopen it.

Verification covers short/long Space delivery into a native editor, duplicate repeats, threshold/release races, cancellation, width continuity, a fixed native window envelope, Reduce Motion, existing playback shortcuts and existing island transitions. Installed-app keyboard and visual checks are required in addition to these tests.
