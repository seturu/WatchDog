import Foundation
import WatchDogCore

// Runs every tracking probe once and prints the result. Developer tool only.
// Permission-gated probes report on the app that launched this (your terminal),
// so "not granted" here says nothing about WatchDog.app itself.

func show<T>(_ label: String, _ result: Result<T, ProbeError>) {
    switch result {
    case .success(let value): print("\(label): \(value)")
    case .failure(let error): print("\(label): FAILED — \(error)")
    }
}

if let app = Probes.frontApp() {
    print("front app: \(app.name) [\(app.bundleID)] pid \(app.pid)")
    show("window title", Probes.windowTitle(pid: app.pid))
} else {
    print("front app: none")
}
print("idle: \(String(format: "%.1f", Probes.idleSeconds())) s")
print("accessibility granted: \(Probes.accessibilityGranted())")
show("brave url", Probes.braveURL())

switch Probes.audioProcesses() {
case .failure(let error):
    print("audio: FAILED — \(error)")
case .success(let processes):
    let playing = processes.filter(\.isPlaying)
    print("audio: \(processes.count) processes registered, \(playing.count) playing")
    for p in playing { print("  playing: \(p.bundleID) pid \(p.pid)") }
}
