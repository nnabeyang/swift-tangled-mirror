import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  func sendStreaming(_ request: URLRequest) async throws -> (HTTPBodyStream, HTTPURLResponse)
}

extension HTTPTransport {
  public func sendStreaming(
    _ request: URLRequest
  ) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    let (data, response) = try await send(request)
    return (HTTPBodyStream(buffered: data), response)
  }
}

public struct HTTPBodyStream: AsyncSequence, Sendable {
  public typealias Element = Data
  public typealias Failure = any Error

  private let nextChunk: @Sendable () async throws -> Data?
  private let cancelOperation: @Sendable () -> Void

  fileprivate init(storage: HTTPBodyStreamStorage) {
    nextChunk = { try await storage.next() }
    cancelOperation = { storage.cancel() }
  }

  public init(
    unfolding nextChunk: @escaping @Sendable () async throws -> Data?,
    onCancel: @escaping @Sendable () -> Void = {}
  ) {
    self.nextChunk = nextChunk
    cancelOperation = onCancel
  }

  init(buffered data: Data) {
    let storage = HTTPBodyStreamStorage()
    self.init(storage: storage)
    storage.receive(data)
    storage.finish()
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(nextChunk: nextChunk)
  }

  public func cancel() {
    cancelOperation()
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = Data
    public typealias Failure = any Error

    fileprivate let nextChunk: @Sendable () async throws -> Data?

    public mutating func next() async throws -> Data? {
      try await nextChunk()
    }
  }
}

public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TangledError.serverStatus(-1, "Non-HTTP response")
    }
    return (data, http)
  }

  public func sendStreaming(
    _ request: URLRequest
  ) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    let storage = HTTPBodyStreamStorage()
    let delegate = HTTPBodyStreamDelegate(storage: storage)
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    let streamingSession = URLSession(
      configuration: session.configuration,
      delegate: delegate,
      delegateQueue: delegateQueue
    )
    return try await delegate.start(request: request, session: streamingSession)
  }
}

protocol HTTPBodyStreamTaskControlling: Sendable {
  func suspend()
  func resume()
  func cancel()
}

protocol HTTPBodyStreamSessionControlling: Sendable {
  func finish()
  func cancel()
}

private final class URLSessionDataTaskController: HTTPBodyStreamTaskControlling,
  @unchecked Sendable
{
  private let task: URLSessionDataTask

  init(task: URLSessionDataTask) {
    self.task = task
  }

  func suspend() {
    task.suspend()
  }

  func resume() {
    task.resume()
  }

  func cancel() {
    task.cancel()
  }
}

private final class URLSessionController: HTTPBodyStreamSessionControlling, @unchecked Sendable {
  private let session: URLSession

  init(session: URLSession) {
    self.session = session
  }

  func finish() {
    session.finishTasksAndInvalidate()
  }

  func cancel() {
    session.invalidateAndCancel()
  }
}

final class HTTPBodyStreamStorage: @unchecked Sendable {
  private enum Terminal {
    case finished
    case failed(any Error)
  }

  private let condition = NSCondition()
  private var bufferedChunk: Data?
  private var waiting: CheckedContinuation<Data?, any Error>?
  private var terminal: Terminal?
  private var taskController: (any HTTPBodyStreamTaskControlling)?
  private var sessionController: (any HTTPBodyStreamSessionControlling)?
  private var suspended = false

  func attach(task: URLSessionDataTask, session: URLSession) {
    attach(
      taskController: URLSessionDataTaskController(task: task),
      sessionController: URLSessionController(session: session)
    )
  }

  func attach(
    taskController: any HTTPBodyStreamTaskControlling,
    sessionController: any HTTPBodyStreamSessionControlling
  ) {
    condition.lock()
    self.taskController = taskController
    self.sessionController = sessionController
    condition.unlock()
  }

  func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    condition.lock()
    while bufferedChunk != nil && terminal == nil {
      condition.wait()
    }
    guard terminal == nil else {
      condition.unlock()
      return
    }
    if let waiting {
      self.waiting = nil
      condition.unlock()
      waiting.resume(returning: data)
      return
    }
    bufferedChunk = data
    if let taskController, !suspended {
      taskController.suspend()
      suspended = true
    }
    condition.unlock()
  }

  func finish(error: (any Error)? = nil) {
    condition.lock()
    guard terminal == nil else {
      condition.unlock()
      return
    }
    terminal = error.map(Terminal.failed) ?? .finished
    let waiting = waiting
    self.waiting = nil
    let sessionController = sessionController
    self.sessionController = nil
    taskController = nil
    condition.broadcast()
    condition.unlock()

    if let error {
      waiting?.resume(throwing: error)
    } else {
      waiting?.resume(returning: nil)
    }
    sessionController?.finish()
  }

  func cancel() {
    condition.lock()
    guard terminal == nil else {
      condition.unlock()
      return
    }
    terminal = .failed(CancellationError())
    bufferedChunk = nil
    let waiting = waiting
    self.waiting = nil
    let taskController = taskController
    self.taskController = nil
    let sessionController = sessionController
    self.sessionController = nil
    condition.broadcast()
    condition.unlock()

    waiting?.resume(throwing: CancellationError())
    taskController?.cancel()
    sessionController?.cancel()
  }

  func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        condition.lock()
        if let bufferedChunk {
          self.bufferedChunk = nil
          if suspended {
            taskController?.resume()
            suspended = false
          }
          condition.broadcast()
          condition.unlock()
          continuation.resume(returning: bufferedChunk)
          return
        }
        if let terminal {
          condition.unlock()
          switch terminal {
          case .finished:
            continuation.resume(returning: nil)
          case .failed(let error):
            continuation.resume(throwing: error)
          }
          return
        }
        guard waiting == nil else {
          condition.unlock()
          continuation.resume(
            throwing: TangledError.transport(
              "HTTP body stream does not support concurrent iteration"
            )
          )
          return
        }
        waiting = continuation
        condition.unlock()
      }
    } onCancel: {
      cancel()
    }
  }
}

private final class HTTPBodyStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private typealias StartContinuation =
    CheckedContinuation<(HTTPBodyStream, HTTPURLResponse), any Error>

  private let lock = NSLock()
  private let storage: HTTPBodyStreamStorage
  private var startContinuation: StartContinuation?

  init(storage: HTTPBodyStreamStorage) {
    self.storage = storage
  }

  func start(
    request: URLRequest,
    session: URLSession
  ) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          startContinuation = continuation
        }
        let task = session.dataTask(with: request)
        storage.attach(task: task, session: session)
        task.resume()
      }
    } onCancel: {
      storage.cancel()
      failStart(CancellationError())
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      let error = TangledError.serverStatus(-1, "Non-HTTP response")
      failStart(error)
      storage.finish(error: error)
      return
    }
    completionHandler(.allow)
    takeStartContinuation()?.resume(
      returning: (HTTPBodyStream(storage: storage), response)
    )
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    storage.receive(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      failStart(error)
    }
    storage.finish(error: error)
  }

  private func takeStartContinuation() -> StartContinuation? {
    lock.withLock {
      defer { startContinuation = nil }
      return startContinuation
    }
  }

  private func failStart(_ error: any Error) {
    takeStartContinuation()?.resume(throwing: error)
  }
}
