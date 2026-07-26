// The generated sh.tangled.ci.queryPipelines source refers to an array item's
// enum by an unqualified name. Keep the generated source untouched and provide
// the missing alias until the generator emits the qualified name.
extension Sh.Tangled {
  public typealias kinds__Elem = CiQueryPipelines_Kinds_Elem
}

extension Sh.Tangled.CiQueryPipelines_Kinds_Elem: CustomStringConvertible {
  public var description: String { rawValue }
}
