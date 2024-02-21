# Class: datadog_agent::windows
#
# This class contains the DataDog agent installation mechanism for Windows
#
# Parameters:
#   Integer $agent_major_version:
#     The major version of the Datadog Agent to install. Defaults to the value of `$datadog_agent::params::default_agent_major_version`.
#
#   String $agent_version:
#     The specific version of the Datadog Agent to install. Defaults to the value of `$datadog_agent::params::agent_version`.
#
#   Optional[String] $agent_repo_uri:
#     The URI of the repository to use for installing the Datadog Agent. Defaults to `undef`.
#
#   String $msi_location:
#     The location where the MSI installer file will be downloaded. Defaults to 'C:/Windows/temp'.
#
#   Variant[String, Sensitive[String]] $api_key:
#     The API key to use for authenticating with the Datadog service. Defaults to the value of `$datadog_agent::api_key`.
#
#   String $hostname:
#     The hostname to use for identifying the host in the Datadog service. Defaults to the value of `$datadog_agent::host`.
#
#   Array $tags:
#     An array of tags to associate with the host in the Datadog service. Defaults to the value of `$datadog_agent::tags`.
#
#   String $tags_join:
#     The string used to join the tags array into a single string. Defaults to the result of `join($tags,',')`.
#
#   String $tags_quote_wrap:
#     The string used to wrap the joined tags string. Defaults to "\"${tags_join}\"".
#
#   Enum['present', 'absent'] $ensure:
#     Whether the Datadog Agent should be present or absent on the host. Defaults to 'present'.
#
#   Boolean $npm_install:
#     Whether to install the Datadog NPM package. Defaults to false.
#
#   Optional[String] $ddagentuser_name:
#     The username for the Datadog Agent user. Defaults to `undef`.
#
#   Optional[String] $ddagentuser_password:
#     The password for the Datadog Agent user. Defaults to `undef`.
#
# Examples:
#   class { 'datadog_agent':
#     agent_major_version => 7,
#     agent_version       => '7.2.0',
#     api_key             => 'your-api-key',
#     hostname            => 'your-hostname',
#     tags                => ['tag1', 'tag2'],
#     ensure              => 'present',
#   }
#
#   class { 'datadog_agent':
#     agent_major_version => 7,
#     agent_version       => '7.2.0',
#     api_key             => Sensitive('your-sensitive-api-key'),
#     hostname            => 'your-hostname',
#     tags                => ['tag1', 'tag2'],
#     ensure              => 'present',
#   }
class datadog_agent::windows(
  Integer $agent_major_version = $datadog_agent::params::default_agent_major_version,
  String $agent_version = $datadog_agent::params::agent_version,
  Optional[String] $agent_repo_uri = undef,
  String $msi_location = 'C:/Windows/temp',
  Variant[String, Sensitive[String]] $api_key = $datadog_agent::api_key,
  String $hostname = $datadog_agent::host,
  Array  $tags = $datadog_agent::tags,
  String $tags_join = join($tags,','),
  String $tags_quote_wrap = "\"${tags_join}\"",
  Enum['present', 'absent'] $ensure = 'present',
  Boolean $npm_install = false,
  Optional[String] $ddagentuser_name = undef,
  Optional[String] $ddagentuser_password = undef,
) inherits datadog_agent::params {

  $msi_full_path = "${msi_location}/datadog-agent-${agent_major_version}-${agent_version}.amd64.msi"

  if ($agent_repo_uri != undef) {
    $baseurl = $agent_repo_uri
  } else {
    $baseurl = 'https://s3.amazonaws.com/ddagent-windows-stable/'
  }

  if $agent_version == 'latest' {
    $msi_source = "${baseurl}datadog-agent-${agent_major_version}-latest.amd64.msi"
  } else {
    $msi_source = "${baseurl}ddagent-cli-${agent_version}.msi"
  }

  if $ensure == 'present' {
    if ($agent_version in ['6.14.0', '6.14.1']) {
      fail('The specified agent version has been blacklisted, please specify a version other than 6.14.0 or 6.14.1')
    }

    file { 'installer':
      path     => $msi_full_path,
      source   => $msi_source,
      provider => 'windows',
    }

    exec { 'assert-acceptable-msi':,
      command   => 'Exit 1',
      unless    => @(ACCEPTABLE),
        $blacklist = '928b00d2f952219732cda9ae0515351b15f9b9c1ea1d546738f9dc0fda70c336','78b2bb2b231bcc185eb73dd367bfb6cb8a5d45ba93a46a7890fd607dc9188194';
        $fileStream = [system.io.file]::openread('${msi_full_path}');
        $hasher = [System.Security.Cryptography.HashAlgorithm]::create('sha256');
        $hash = $hasher.ComputeHash($fileStream);
        $fileStream.close();
        $fileStream.dispose();
        $hexhash = [system.bitconverter]::tostring($hash).ToLower().replace('-','');
        if ($blacklist.Contains($hexhash)) { Exit 1 } else { Exit 0 }
        | ACCEPTABLE
      provider  => 'powershell',
      logoutput => 'on_failure',
      require   => File['installer'],
      notify    => Package[$datadog_agent::params::package_name],
    }

    if $agent_version == 'latest' {
      $ensure_version = 'installed'
    } else {
      # While artifacts contain X.Y.Z in their name, their installed Windows versions are actually X.Y.Z.1
      $ensure_version = "${agent_version}.1"
    }

    $hostname_option = $hostname ? { '' => {}, default => { 'HOSTNAME' => $hostname } }
    $npm_install_option = $npm_install ? { false => {}, true => { 'ADDLOCAL' => 'MainApplication,NPM' } }
    $ddagentuser_name_option = $ddagentuser_name ? { undef => {}, default => { 'DDAGENTUSER_NAME' => $ddagentuser_name}}
    $ddagentuser_password_option = ($ddagentuser_name != undef and $ddagentuser_password != undef) ? { true => {'DDAGENTUSER_PASSWORD' => $ddagentuser_password}, false => {}}

    package { $datadog_agent::params::package_name:
      ensure          => $ensure_version,
      provider        => 'windows',
      source          => $msi_full_path,
      install_options => ['/norestart', {'APIKEY' => $api_key, 'TAGS' => $tags_quote_wrap} + $npm_install_option + $hostname_option + $ddagentuser_name_option + $ddagentuser_password_option]
    }

  } else {
    exec { 'datadog_6_14_fix':
      command  => "((New-Object System.Net.WebClient).DownloadFile('https://s3.amazonaws.com/ddagent-windows-stable/scripts/fix_6_14.ps1', \$env:temp + '\\fix_6_14.ps1')); &\$env:temp\\fix_6_14.ps1",
      provider => 'powershell',
    }

    package { $datadog_agent::params::package_name:
      ensure            => absent,
      provider          => 'windows',
      uninstall_options => ['/quiet'],
      subscribe         => Exec['datadog_6_14_fix'],
    }

  }
}
