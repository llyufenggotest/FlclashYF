// Actual IOSCoreBridge dependency double: controllable socket ownership barrier.
enum IOSCoreBridge {
  static var calls: [String] = []
  static var holdSuspend = false, holdResume = false
  static var heldSuspend: ((String?) -> Void)?
  static var heldResume: ((String?) -> Void)?
  static var suspendReply: String? = #"{"result":true,"error":null}"#
  static var resumeReply: String? = #"{"result":true,"error":null}"#
  static func invokeMethod(_ data: String, completion: @escaping (String?) -> Void) {
    let obj = try! JSONSerialization.jsonObject(with: Data(data.utf8)) as! [String: Any]
    let method = obj["method"] as! String
    calls.append(method)
    if method == "suspendDnsListener" {
      if holdSuspend { heldSuspend = completion } else { completion(suspendReply) }
    } else if method == "resumeDnsListener" {
      if holdResume { heldResume = completion } else { completion(resumeReply) }
    } else { completion(#"{"result":"","error":null}"#) }
  }
}
