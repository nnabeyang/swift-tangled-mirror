// swift-atproto 0.42.1 generates an unqualified name for an array item's enum in
// sh.tangled.ci.queryPipelines. Keep the generated source untouched and provide
// the missing alias until the generator dependency is updated.
extension Sh.Tangled {
  public typealias kinds__Elem = CiQueryPipelines_Kinds_Elem
}

extension Sh.Tangled.CiQueryPipelines_Kinds_Elem: CustomStringConvertible {
  public var description: String { rawValue }
}
