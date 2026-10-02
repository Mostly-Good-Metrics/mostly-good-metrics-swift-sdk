import MostlyGoodMetrics

actor FlushOwner {
    private var completionCount = 0

    func flush(_ client: MostlyGoodMetrics) {
        // This compiled with the old unannotated callback and could trap when
        // the SDK invoked this actor-inheriting closure on its main queue.
        // The MainActor completion contract must reject the actor-state access.
        client.flush { _ in
            self.completionCount += 1
        }
    }
}

@main
struct CustomActorFlush {
    static func main() {}
}
