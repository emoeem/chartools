/// The HTTP calls that belong to one unit of work (an analysis round, a redraft,
/// a refine), so a watchdog can *close their sockets* instead of only
/// interrupting the work that is blocked on them.
///
/// In Dart the same idea lands on `HttpClientRequest.abort()`: an abandoned
/// round aborts its request/response immediately instead of waiting out a read
/// timeout while quota and connections stay alive.
///
/// Cancelling is sticky: a call attached after [cancel] is cancelled at once, so
/// a late straggler from a dead round cannot slip through.
class HttpScope {
  final List<void Function()> _cancels = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// Register how to tear one in-flight request down. The SAME function
  /// instance must be passed to [detach], which is why callers keep it in a
  /// local variable instead of writing the closure inline twice.
  void attach(void Function() cancel) {
    _cancels.add(cancel);
    if (_cancelled) cancel();
  }

  void detach(void Function() cancel) {
    _cancels.remove(cancel);
  }

  /// Close every socket this scope owns. Safe any number of times.
  void cancel() {
    _cancelled = true;
    for (final c in List.of(_cancels)) {
      c();
    }
    _cancels.clear();
  }
}
