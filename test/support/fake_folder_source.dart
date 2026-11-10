// An in-memory server file system for the folder picker: directories only,
// like what `SftpFolderSource` hands the UI.
import 'package:hermes_android/core/services/herdr_folders.dart';

class FakeFolderSource implements HerdrFolderSource {
  FakeFolderSource({
    Map<String, List<String>>? tree,
    this.homePath = '/home/demo',
    Set<String>? git,
  }) : tree =
           tree ??
           {
             '/': ['home', 'srv'],
             '/home': ['demo'],
             '/home/demo': ['proyectos', '.config', 'Zeta', 'alpha'],
             '/home/demo/proyectos': ['app', 'web'],
             '/home/demo/proyectos/app': ['lib'],
             '/home/demo/proyectos/web': [],
             '/home/demo/.config': [],
             '/home/demo/Zeta': [],
             '/home/demo/alpha': [],
             '/home/demo/proyectos/app/lib': [],
             '/srv': [],
           },
       git = git ?? {'/home/demo/proyectos/app'};

  final Map<String, List<String>> tree;
  final Set<String> git;
  final String homePath;

  /// Paths `makeDirectory` created.
  final List<String> made = [];
  final List<String> listed = [];
  bool failList = false;
  bool failMkdir = false;

  @override
  Future<String> home() async => homePath;

  @override
  Future<HerdrDirListing> list(String path) async {
    listed.add(path);
    final children = tree[path];
    if (failList || children == null) throw StateError('unreadable');
    final dirs = [for (final name in children) HerdrDirEntry(name)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return HerdrDirListing(path: path, dirs: dirs, isGit: git.contains(path));
  }

  @override
  Future<bool> isDirectory(String path) async => tree.containsKey(path);

  @override
  Future<void> makeDirectory(String path) async {
    final parent = herdrParentPath(path);
    final children = tree[parent];
    if (failMkdir || children == null) throw StateError('denied');
    final name = path.substring(path.lastIndexOf('/') + 1);
    if (children.contains(name)) throw StateError('exists');
    children.add(name);
    tree[path] = [];
    made.add(path);
  }
}
