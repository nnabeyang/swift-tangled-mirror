import Foundation
import Logging
import SwiftAtproto
import Synchronization
import WSClient

struct WebSocketXRPCSubscriptionTransport: XRPCSubscriptionTransport {
  private static let bufferCapacity = SpindleClient.pipelineLogBufferCapacity
  private static let maximumMessageBytes = 2 * 1_024 * 1_024

  func connect(_ request: XRPCWebSocketRequest) async throws -> XRPCWebSocketConnection {
    let taskState = SubscriptionTaskState()
    let messages = AsyncThrowingStream<XRPCWebSocketMessage, any Error>(
      bufferingPolicy: .bufferingOldest(Self.bufferCapacity)
    ) { continuation in
      let task = Task {
        do {
          let closeFrame = try await WebSocketClient.connect(
            url: request.url.absoluteString,
            configuration: .init(
              maxFrameSize: Self.maximumMessageBytes,
              additionalHeaders: request.headers,
              autoPing: .enabled(timePeriod: .seconds(30)),
              validateUTF8: true
            ),
            logger: Logger(label: "SwiftTangled.SpindleSubscription")
          ) { inbound, _, _ in
            for try await message in inbound.messages(maxSize: Self.maximumMessageBytes) {
              try Task.checkCancellation()
              let result:
                AsyncThrowingStream<XRPCWebSocketMessage, any Error>.Continuation
                  .YieldResult
              switch message {
              case .binary(let buffer):
                result = continuation.yield(.binary(Data(buffer.readableBytesView)))
              case .text(let text):
                result = continuation.yield(.text(text))
              }
              switch result {
              case .enqueued:
                break
              case .dropped:
                throw XRPCSubscriptionStreamError.bufferOverflow(
                  limit: Self.bufferCapacity
                )
              case .terminated:
                throw CancellationError()
              @unknown default:
                throw XRPCSubscriptionStreamError.bufferOverflow(
                  limit: Self.bufferCapacity
                )
              }
            }
          }
          if let closeFrame {
            switch closeFrame.closeCode {
            case .normalClosure:
              break
            default:
              throw TangledError.transport(
                "Spindle WebSocket closed: \(String(describing: closeFrame.closeCode))"
              )
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch let error as XRPCSubscriptionStreamError {
          continuation.finish(throwing: error)
        } catch let error as TangledError {
          continuation.finish(throwing: error)
        } catch let error as WebSocketClientError {
          continuation.finish(throwing: TangledError.transport(error.description))
        } catch {
          continuation.finish(throwing: TangledError.transport(String(describing: error)))
        }
      }
      taskState.install(task)
      continuation.onTermination = { @Sendable _ in
        taskState.cancel()
      }
    }
    return XRPCWebSocketConnection(
      messages: messages,
      close: {
        taskState.cancel()
      }
    )
  }
}

private final class SubscriptionTaskState: Sendable {
  private struct State {
    var task: Task<Void, Never>?
    var cancelled = false
  }

  private let state = Mutex(State())

  func install(_ task: Task<Void, Never>) {
    let shouldCancel = state.withLock { state in
      if state.cancelled {
        return true
      }
      state.task = task
      return false
    }
    if shouldCancel {
      task.cancel()
    }
  }

  func cancel() {
    let task = state.withLock { state in
      state.cancelled = true
      return state.task
    }
    task?.cancel()
  }
}
