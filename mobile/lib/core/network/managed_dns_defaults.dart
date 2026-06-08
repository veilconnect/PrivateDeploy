const managedDnsRemoteTag = 'dns-remote';
const managedDnsRemoteFallbackTag = 'dns-remote-google';
const managedDnsBootstrapTag = 'dns-direct';
const managedDnsLocalTag = 'dns-local';
const managedDnsCnTag = 'dns-cn';

const managedDnsRemoteAddress = 'https://1.1.1.1/dns-query';
const managedDnsRemoteFallbackAddress = 'https://8.8.8.8/dns-query';
const managedDnsBootstrapAddress = 'https://1.12.12.12/dns-query';
const managedDnsCnAddress = 'https://223.5.5.5/dns-query';

const managedDnsRemoteHosts = {'1.1.1.1', '1.0.0.1'};
const managedDnsRemoteFallbackHosts = {'8.8.8.8', '8.8.4.4'};
const managedDnsBootstrapHosts = {'1.12.12.12'};
const managedDnsCnHosts = {
  '223.5.5.5',
  '223.6.6.6',
  '119.29.29.29',
  '180.76.76.76',
};

const managedDnsRemoteFallbackDomainSuffixes = [
  'google.com',
  'googleapis.com',
  'gstatic.com',
  'googlevideo.com',
  'youtube.com',
  'youtu.be',
  'ytimg.com',
  'ggpht.com',
  'withgoogle.com',
  'wikipedia.org',
  'wikimedia.org',
  'wiktionary.org',
  'mediawiki.org',
];

const managedDnsCacheCapacity = 4096;
