// A bounded live Dart child exposes reaper races; fake HIP proves no GPU or packaged bridge behavior.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef NativeProbe = Int32 Function();
typedef DartProbe = int Function();

int invoke(DynamicLibrary library, String name) =>
    library.lookupFunction<NativeProbe, DartProbe>(name)();

Map<String, int?> runChecks(
  DynamicLibrary library,
  bool expectLoss,
  Map<int, int> results,
) {
  final probe = library.lookupFunction<NativeProbe, DartProbe>(
    expectLoss ? 'ant_probe_original_child' : 'ant_probe_native_child',
  );
  for (var index = 0; index < 64; index++) {
    final result = probe();
    results[result] = (results[result] ?? 0) + 1;
  }
  return {
    'status': expectLoss ? null : invoke(library, 'ant_probe_native_statuses'),
    'hip': expectLoss ? null : invoke(library, 'ant_probe_native_hip'),
    'reaps': invoke(library, 'ant_probe_foreign_reaps'),
    'module': invoke(library, 'ant_probe_module_owner'),
  };
}

Future<void> main(List<String> args) async {
  if (args.length != 1 && args.length != 2) {
    throw ArgumentError(
      'expected library and optional --expect-status-loss or --idle-reaper',
    );
  }
  final mode = args.length == 2 ? args[1] : '';
  final expectLoss = mode == '--expect-status-loss';
  final idleReaper = mode == '--idle-reaper';
  if (mode.isNotEmpty && !expectLoss && !idleReaper)
    throw ArgumentError('unknown probe mode');
  final module = File(args[0]).absolute;
  Directory.current = module.parent;
  final library = DynamicLibrary.open('./${module.uri.pathSegments.last}');
  Directory.current = Directory.systemTemp;
  final results = <int, int>{};
  final duration = Stopwatch()..start();
  final child = idleReaper ? null : await Process.start('/bin/sleep', ['60']);
  late Map<String, int?> controls;
  var childSignalled = true;
  try {
    controls = runChecks(library, expectLoss, results);
  } finally {
    duration.stop();
    if (child != null) {
      childSignalled = child.kill(ProcessSignal.sigterm);
      await child.exitCode;
    }
  }
  final lost = results[10] ?? 0;
  final success = results[0] ?? 0;
  final accepted =
      childSignalled &&
      controls['module'] == 0 &&
      duration.elapsed < const Duration(seconds: 30) &&
      (expectLoss
          ? lost > 0
          : success == 64 &&
                controls['status'] == 0 &&
                controls['hip'] == 0 &&
                (idleReaper || controls['reaps']! > 0));
  stdout.writeln(
    jsonEncode({
      'mode': expectLoss ? 'original-failure-control' : 'required-success',
      'dart_child_active': !idleReaper,
      'dart_child_signalled': childSignalled,
      'active_probe_milliseconds': duration.elapsedMilliseconds,
      'status_and_timeout_control': controls['status'],
      'hip_fixture_control': controls['hip'],
      'module_owner_control': controls['module'],
      'hip_fixture_leak_device':
          Platform.environment['ANT_TEST_HIP_LEAK_DEVICE'],
      'supervisor_statuses_reaped_externally': controls['reaps'],
      'attempts': 64,
      'successful_children': success,
      'lost_status_echild': lost,
      'results': results.map((key, value) => MapEntry('$key', value)),
      'accepted': accepted,
    }),
  );
  if (!accepted) exitCode = 1;
}
