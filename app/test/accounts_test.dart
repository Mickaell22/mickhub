import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/accounts.dart';
import 'package:mickhub/avatar.dart';

void main() {
  const personal = Account(id: 'p', label: 'Personal', githubUser: 'Mickaell22', gitName: 'Mick', gitEmail: 'mick@personal.test');
  const otraGh = Account(id: 'o', label: 'Otra', githubUser: 'otra-cuenta');
  // El trabajo: un GitHub propio y los repos en una organización de Azure.
  const trabajo = Account(
    id: 't',
    label: 'Trabajo',
    githubUser: 'mmoran-trabajo',
    azureOrgs: ['LuckyERP'],
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
    expect(accountFor('https://github.com/mmoran-trabajo/notas.git', all)?.id, 't');
    expect(accountFor('https://otra-cuenta@github.com/empresa/x.git', all)?.id, 'o');
    expect(accountFor('https://github.com/empresa/x.git', all), isNull); // varias de GitHub y ninguna calza
    expect(accountFor('https://github.com/empresa/x.git', [personal])?.id, 'p'); // una sola: esa
    expect(accountFor('https://dev.azure.com/OtraOrg/P/_git/x', all), isNull);
    expect(accountFor('https://github.com/Mickaell22/surco.git', all, overrideId: 't')?.id, 't');
  });

  test('lugares, identidad y consulta de credencial por cuenta', () {
    expect(trabajo.identityArgs, ['-c', 'user.name=M. Morán', '-c', 'user.email=mmoran@empresa.test']);
    expect(otraGh.identityArgs, isEmpty);
    expect(trabajo.targets.map((t) => t.label), ['GitHub mmoran-trabajo', 'Azure LuckyERP']);
    expect(trabajo.targets.last.credentialQuery(), 'protocol=https\nhost=dev.azure.com\npath=LuckyERP\n\n');
    expect(personal.targets.single.credentialQuery(), contains('username=Mickaell22'));
    expect(Account.fromJson(trabajo.toJson()).azureOrgs, ['LuckyERP']);
    expect(targetOf('https://LuckyERP@dev.azure.com/LuckyERP/P/_git/Erp'), const Target(Provider.azure, 'luckyerp'));
  });

  test('las cuentas guardadas con el formato viejo se convierten solas', () {
    final gh = Account.fromJson({'id': '1', 'label': 'Personal', 'provider': 'github', 'org': '', 'username': 'Mickaell22'});
    final az = Account.fromJson({'id': '2', 'label': 'Trabajo', 'provider': 'azure', 'org': 'LuckyERP'});
    expect(gh.githubUser, 'Mickaell22');
    expect(gh.azureOrgs, isEmpty);
    expect(az.githubUser, isNull);
    expect(az.azureOrgs, ['LuckyERP']);
  });

  test('isAuthError reconoce credenciales vencidas de git', () {
    expect(isAuthError("fatal: Authentication failed for 'https://dev.azure.com/x/'"), isTrue);
    expect(isAuthError('fatal: could not read Username for https://dev.azure.com: terminal prompts disabled'), isTrue);
    expect(isAuthError('error: Your local changes would be overwritten by merge'), isFalse);
  });

  test('avatares: noreply de GitHub por id y el resto por email', () {
    expect(avatarForEmail('123+mick@users.noreply.github.com', size: 40), 'https://avatars.githubusercontent.com/u/123?s=40');
    expect(avatarForEmail('Ana@Empresa.com', size: 40), 'https://avatars.githubusercontent.com/u/e?email=ana%40empresa.com&s=40');
  });

  test('commitWebUrl arma el link del commit en GitHub y Azure', () {
    expect(commitWebUrl('https://github.com/Mickaell22/mickhub.git', 'abc'), 'https://github.com/Mickaell22/mickhub/commit/abc');
    expect(commitWebUrl('git@github.com:Mickaell22/surco.git', 'abc'), 'https://github.com/Mickaell22/surco/commit/abc');
    expect(
      commitWebUrl('https://LuckyERP@dev.azure.com/LuckyERP/ERP/_git/Erp_DB', 'abc'),
      'https://dev.azure.com/LuckyERP/ERP/_git/Erp_DB/commit/abc',
    );
  });

  test('azureOrgFrom saca la organización de lo que se pegue', () {
    for (final input in [
      'miorg',
      ' miorg ',
      'https://dev.azure.com/miorg/Proyecto/_git/repo',
      'https://yo@dev.azure.com/miorg/Proyecto/_git/repo',
      'dev.azure.com/miorg',
      'https://miorg.visualstudio.com/Proyecto',
      'git@ssh.dev.azure.com:v3/miorg/Proyecto/repo',
    ]) {
      expect(azureOrgFrom(input), 'miorg', reason: input);
    }
  });

  test('azureConnectionUser: email del usuario, null si es anónimo o no es JSON', () {
    expect(
      azureConnectionUser(
        '{"authenticatedUser":{"providerDisplayName":"Yo","properties":{"Account":{"\$type":"System.String","\$value":"yo@empresa.com"}}}}',
      ),
      'yo@empresa.com',
    );
    expect(azureConnectionUser('{"authenticatedUser":{"providerDisplayName":"Yo"}}'), 'Yo');
    expect(azureConnectionUser('{"authenticatedUser":{"providerDisplayName":"Anonymous"}}'), isNull);
    expect(azureConnectionUser('<html>login</html>'), isNull);
    expect(
      azureConnectionUser(
        '{"authenticatedUser":{"descriptor":"System:PublicAccess;aaaa","providerDisplayName":"X",'
        '"properties":{"Account":{"\$value":"Anonymous"}}}}',
      ),
      isNull,
    );
  });

  test('ghLoginCommand vuelve a la cuenta activa solo si es otra', () {
    expect(
      ghLoginCommand('Trabajo', active: 'Personal'),
      'gh auth login --hostname github.com --git-protocol https --web && gh auth switch -u Personal',
    );
    expect(ghLoginCommand('Trabajo', active: 'trabajo'), 'gh auth login --hostname github.com --git-protocol https --web');
    expect(ghLoginCommand('Trabajo'), 'gh auth login --hostname github.com --git-protocol https --web');
  });
}
