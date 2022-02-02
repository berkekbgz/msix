import 'dart:io';
import 'package:msix/src/extensions.dart';
import 'package:path/path.dart';
import 'configuration.dart';
import 'log.dart';

var _publisherRegex = RegExp(
    '(CN|L|O|OU|E|C|S|STREET|T|G|I|SN|DC|SERIALNUMBER|(OID\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))+))=(([^,+="<>#;])+|".*")(, ((CN|L|O|OU|E|C|S|STREET|T|G|I|SN|DC|SERIALNUMBER|(OID\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))+))=(([^,+="<>#;])+|".*")))*');

/// Handles signing operations
class SignTool {
  Configuration _config;
  Log _log;

  SignTool(this._config, this._log);

  /// Use the certutil.exe tool to detect the certificate publisher name (Subject)
  Future<void> getCertificatePublisher(bool withLogs) async {
    const taskName = 'getting certificate publisher';
    _log.startingTask(taskName);

    var certificateDetails = await Process.run('certutil',
        ['-dump', '-p', _config.certificatePassword!, _config.certificatePath!],
        runInShell: true);

    if (certificateDetails.stderr.toString().length > 0) {
      if (certificateDetails.stderr.toString().contains('password')) {
        throw 'Fail to read the certificate details, check if the certificate password is correct';
      }
      _log.error(certificateDetails.stdout);
      throw certificateDetails.stderr;
    } else if (certificateDetails.exitCode != 0) {
      throw certificateDetails.stdout;
    }

    if (withLogs)
      _log.info('Certificate Details: ${certificateDetails.stdout}');

    try {
      var subjectRow = certificateDetails.stdout
          .toString()
          .split('\n')
          .lastWhere((row) => _publisherRegex.hasMatch(row));
      if (withLogs) _log.info('subjectRow: $subjectRow');
      _config.publisher = subjectRow
          .substring(subjectRow.indexOf(':') + 1, subjectRow.length)
          .trim();
      if (withLogs) _log.info('config.publisher: ${_config.publisher}');
    } catch (err, stackTrace) {
      if (!withLogs) await getCertificatePublisher(true);
      _log.error(err.toString());
      if (withLogs)
        _log.warn(
            'This error happen when this package tried to read the certificate details,');
      if (withLogs)
        _log.warn(
            'please report it by pasting all this output (after deleting sensitive info) to:');
      if (withLogs) _log.link('https://github.com/YehudaKremer/msix/issues');
      throw stackTrace;
    }

    _log.taskCompleted(taskName);
  }

  /// Use the certutil.exe tool to install the certificate on the local machine
  /// this helps to avoid the need to install the certificate by hand
  Future<void> installCertificate() async {
    const taskName = 'installing certificate';
    _log.startingTask(taskName);

    var installedCertificatesList =
        await Process.run('certutil', ['-store', 'root']);

    if (!installedCertificatesList.stdout
        .toString()
        .contains(_config.publisher!)) {
      var isAdminCheck = await Process.run('net', ['session']);

      if (isAdminCheck.stderr.toString().contains('Access is denied')) {
        throw 'to install the certificate "${_config.certificatePath}" you need to "Run as administrator" once';
      }

      var result = await Process.run('certutil', [
        '-f',
        '-enterprise',
        '-p',
        _config.certificatePassword!,
        '-importpfx',
        'root',
        _config.certificatePath!
      ]);

      if (result.exitCode != 0) {
        throw result.stdout;
      }
    }

    _log.taskCompleted(taskName);
  }

  /// Sign the created msix installer with the certificate
  Future<void> sign() async {
    const taskName = 'signing';
    _log.startingTask(taskName);

    if (!_config.certificatePath.isNull || _config.signToolOptions != null) {
      var signtoolPath =
          '${_config.msixToolkitPath()}/Redist.${_config.architecture}/signtool.exe';

      List<String> signtoolOptions = [];

      if (_config.signToolOptions != null) {
        signtoolOptions = _config.signToolOptions!;
      } else {
        signtoolOptions = [
          '/v',
          '/fd',
          'SHA256',
          '/a',
          '/f',
          _config.certificatePath!,
          if (extension(_config.certificatePath!) == '.pfx') '/p',
          if (extension(_config.certificatePath!) == '.pfx')
            _config.certificatePassword!,
          '/tr',
          'http://timestamp.digicert.com'
        ];
      }

      if (!signtoolOptions.contains('/fd')) {
        _log.error(
            'signtool need "/fb" (file digest algorithm) option, for example: "/fd SHA256", more details:');
        _log.link(
            'https://docs.microsoft.com/en-us/dotnet/framework/tools/signtool-exe#sign-command-options');
        exit(-1);
      }

      ProcessResult signResults = await Process.run(signtoolPath, [
        'sign',
        ...signtoolOptions,
        if (_config.debugSigning) '/debug',
        '${_config.outputPath ?? _config.buildFilesFolder}\\${_config.outputName ?? _config.appName}.msix',
      ]);

      if (_config.debugSigning) _log.info(signResults.stdout.toString());

      if (!signResults.stdout
              .toString()
              .contains('Number of files successfully Signed: 1') &&
          signResults.stderr.toString().length > 0) {
        _log.error(signResults.stdout);
        _log.error(signResults.stderr);

        if (_config.signToolOptions == null &&
            signResults.stdout
                .toString()
                .contains('Error: SignerSign() failed.') &&
            !_config.publisher.isNull) {
          throw 'signing error';
        }

        exit(-1);
      }
    }

    _log.taskCompleted(taskName);
  }
}
