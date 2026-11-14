import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/summaries.dart';

void main() {
  test('repoId: el mismo repo da lo mismo sin importar cómo se clonó', () {
    const id = 'github.com/dueno/repo';
    expect(repoId('https://github.com/dueno/repo.git', '/x'), id);
    expect(repoId('https://usuario:token@github.com/dueno/repo', '/x'), id);
    expect(repoId('git@github.com:dueno/repo.git', '/x'), id);
    expect(repoId('ssh://git@github.com/dueno/repo.git', '/x'), id);
    expect(repoId('https://org@dev.azure.com/org/proy/_git/repo', '/x'), 'dev.azure.com/org/proy/_git/repo');
    expect(repoId('ssh://git@host:2222/dueno/repo.git', '/x'), 'host:2222/dueno/repo');
    expect(repoId(null, '/home/yo/Proyectos/MiRepo'), 'MiRepo');
  });
}
