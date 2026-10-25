import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/accounts.dart';

void main() {
  const personal = Account(
    id: 'p',
    label: 'Personal',
    provider: Provider.github,
    org: '',
    username: 'Mickaell22',
    gitName: 'Mick',
    gitEmail: 'mick@personal.test',
  );
  const otraGh = Account(id: 'o', label: 'Otra', provider: Provider.github, org: '', username: 'otra-cuenta');
  const trabajo = Account(
    id: 't',
    label: 'Trabajo',
    provider: Provider.azure,
    org: 'LuckyERP',
    gitName: 'M. Morán',
    gitEmail: 'mmoran@empresa.test',
  );
  const all = [personal, otraGh, trabajo];

  test('parseRemote entiende https, usuario embebido y ssh de Azure', () {
    final r = parseRemote('https://LuckyERP@dev.azure.com/LuckyERP/Proyecto/_git/Erp')!;
    expect((r.host, r.owner, r.user, r.isAzure), ('dev.azure.com', 'LuckyERP', 'LuckyERP', true));
    expect(parseRemote('git@ssh.dev.azure.com:v3/LuckyERP/Proyecto/Erp')!.owner, 'LuckyERP');
    expect(parseRemote('https://luckyerp.visualstudio.com/Proyecto/_git/Erp')!.owner, 'luckyerp');
    expect(parseRemote('git@github.com:Mickaell22/surco.git')!.owner, 'Mickaell22');
  });

  test('accountFor: Azure por organización, GitHub por usuario o dueño, override manda', () {
    expect(accountFor('https://dev.azure.com/luckyerp/P/_git/Erp', all)?.id, 't');
    expect(accountFor('https://luckyerp.visualstudio.com/P/_git/Erp', all)?.id, 't');
    expect(accountFor('https://github.com/Mickaell22/surco.git', all)?.id, 'p');
    expect(accountFor('https://otra-cuenta@github.com/empresa/x.git', all)?.id, 'o');
    expect(accountFor('https://github.com/empresa/x.git', all), isNull); // dos cuentas de GitHub y ninguna calza
    expect(accountFor('https://github.com/empresa/x.git', [personal, trabajo])?.id, 'p'); // una sola: esa
    expect(accountFor('https://dev.azure.com/OtraOrg/P/_git/x', all), isNull);
    expect(accountFor('https://github.com/Mickaell22/surco.git', all, overrideId: 't')?.id, 't');
  });

  test('identidad y consulta de credencial por cuenta', () {
    expect(trabajo.identityArgs, ['-c', 'user.name=M. Morán', '-c', 'user.email=mmoran@empresa.test']);
    expect(otraGh.identityArgs, isEmpty);
    expect(trabajo.credentialQuery(), 'protocol=https\nhost=dev.azure.com\npath=LuckyERP\n\n');
    expect(personal.credentialQuery(), contains('username=Mickaell22'));
    expect(Account.fromJson(trabajo.toJson()).org, 'LuckyERP');
  });

  test('isAuthError reconoce credenciales vencidas de git', () {
    expect(isAuthError("fatal: Authentication failed for 'https://dev.azure.com/x/'"), isTrue);
    expect(isAuthError('fatal: could not read Username for https://dev.azure.com: terminal prompts disabled'), isTrue);
    expect(isAuthError('error: Your local changes would be overwritten by merge'), isFalse);
  });
}
