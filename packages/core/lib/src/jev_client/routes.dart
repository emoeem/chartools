/// Which of the three API routes a failure came from. Used to build error text
/// the user can act on ("判断接口 HTTP 401：…" vs "回复接口 …").
abstract final class Route {
  static const judge = '判断接口';
  static const reply = '回复接口';
  static const vision = '视觉接口';
}
