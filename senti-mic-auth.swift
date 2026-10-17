import AVFoundation
import Foundation

// --probe  : report status only, never prompt (AUTHORIZED/DENIED/RESTRICTED/NOTDETERMINED)
// --request: prompt if not yet decided; report result. (default)
let arg = CommandLine.arguments.dropFirst().first ?? "--request"
let status = AVCaptureDevice.authorizationStatus(for: .audio)

func name(_ s: AVAuthorizationStatus) -> String {
  switch s {
  case .authorized:    return "AUTHORIZED"
  case .denied:        return "DENIED"
  case .restricted:    return "RESTRICTED"
  case .notDetermined: return "NOTDETERMINED"
  @unknown default:    return "UNKNOWN"
  }
}

if arg == "--probe" { print(name(status)); exit(status == .authorized ? 0 : 1) }

if status == .authorized { print("AUTHORIZED"); exit(0) }
if status == .denied || status == .restricted { print(name(status)); exit(1) }

let sema = DispatchSemaphore(value: 0)
var ok = false
AVCaptureDevice.requestAccess(for: .audio) { g in ok = g; sema.signal() }
sema.wait()
print(ok ? "AUTHORIZED" : "DENIED")
exit(ok ? 0 : 1)
