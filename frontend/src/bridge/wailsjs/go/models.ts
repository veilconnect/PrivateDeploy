export namespace bridge {
	
	export class CloudProviderInfo {
	    name: string;
	    displayName: string;
	
	    static createFrom(source: any = {}) {
	        return new CloudProviderInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.displayName = source["displayName"];
	    }
	}
	export class PlatformCapabilities {
	    traySupported: boolean;
	    showMainWindowFromTray: boolean;
	    systemProxySupported: boolean;
	    startupLaunchSupported: boolean;
	    startupDelaySupported: boolean;
	    adminElevationSupported: boolean;
	    configurableWebviewGpuPolicy: boolean;
	    kernelGrantPermissionSupported: boolean;
	
	    static createFrom(source: any = {}) {
	        return new PlatformCapabilities(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.traySupported = source["traySupported"];
	        this.showMainWindowFromTray = source["showMainWindowFromTray"];
	        this.systemProxySupported = source["systemProxySupported"];
	        this.startupLaunchSupported = source["startupLaunchSupported"];
	        this.startupDelaySupported = source["startupDelaySupported"];
	        this.adminElevationSupported = source["adminElevationSupported"];
	        this.configurableWebviewGpuPolicy = source["configurableWebviewGpuPolicy"];
	        this.kernelGrantPermissionSupported = source["kernelGrantPermissionSupported"];
	    }
	}
	export class EnvResult {
	    appName: string;
	    appVersion: string;
	    basePath: string;
	    os: string;
	    arch: string;
	    capabilities: PlatformCapabilities;
	
	    static createFrom(source: any = {}) {
	        return new EnvResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.appName = source["appName"];
	        this.appVersion = source["appVersion"];
	        this.basePath = source["basePath"];
	        this.os = source["os"];
	        this.arch = source["arch"];
	        this.capabilities = this.convertValues(source["capabilities"], PlatformCapabilities);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class ExecOptions {
	    StopOutputKeyword: string;
	    Convert: boolean;
	    Env: Record<string, string>;
	
	    static createFrom(source: any = {}) {
	        return new ExecOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.StopOutputKeyword = source["StopOutputKeyword"];
	        this.Convert = source["Convert"];
	        this.Env = source["Env"];
	    }
	}
	export class FlagResult {
	    flag: boolean;
	    data: string;
	
	    static createFrom(source: any = {}) {
	        return new FlagResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.flag = source["flag"];
	        this.data = source["data"];
	    }
	}
	export class HTTPResult {
	    flag: boolean;
	    status: number;
	    headers: Record<string, Array<string>>;
	    body: string;
	
	    static createFrom(source: any = {}) {
	        return new HTTPResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.flag = source["flag"];
	        this.status = source["status"];
	        this.headers = source["headers"];
	        this.body = source["body"];
	    }
	}
	export class IOOptions {
	    Mode: string;
	
	    static createFrom(source: any = {}) {
	        return new IOOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Mode = source["Mode"];
	    }
	}
	export class MenuItem {
	    type: string;
	    text: string;
	    tooltip: string;
	    event: string;
	    children: MenuItem[];
	    hidden: boolean;
	    checked: boolean;
	
	    static createFrom(source: any = {}) {
	        return new MenuItem(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.text = source["text"];
	        this.tooltip = source["tooltip"];
	        this.event = source["event"];
	        this.children = this.convertValues(source["children"], MenuItem);
	        this.hidden = source["hidden"];
	        this.checked = source["checked"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class MultiDeployResult {
	    id: string;
	    success: boolean;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new MultiDeployResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.success = source["success"];
	        this.error = source["error"];
	    }
	}
	export class NotifyOptions {
	    AppName: string;
	    Beep: boolean;
	
	    static createFrom(source: any = {}) {
	        return new NotifyOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.AppName = source["AppName"];
	        this.Beep = source["Beep"];
	    }
	}
	
	export class RequestOptions {
	    Proxy: string;
	    Insecure: boolean;
	    Redirect: boolean;
	    Timeout: number;
	    CancelId: string;
	    FileField: string;
	
	    static createFrom(source: any = {}) {
	        return new RequestOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Proxy = source["Proxy"];
	        this.Insecure = source["Insecure"];
	        this.Redirect = source["Redirect"];
	        this.Timeout = source["Timeout"];
	        this.CancelId = source["CancelId"];
	        this.FileField = source["FileField"];
	    }
	}
	export class ServerOptions {
	    Cert: string;
	    Key: string;
	    StaticPath: string;
	    StaticRoute: string;
	    UploadPath: string;
	    UploadRoute: string;
	    MaxUploadSize: number;
	
	    static createFrom(source: any = {}) {
	        return new ServerOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Cert = source["Cert"];
	        this.Key = source["Key"];
	        this.StaticPath = source["StaticPath"];
	        this.StaticRoute = source["StaticRoute"];
	        this.UploadPath = source["UploadPath"];
	        this.UploadRoute = source["UploadRoute"];
	        this.MaxUploadSize = source["MaxUploadSize"];
	    }
	}
	export class TrayContent {
	    icon: string;
	    title: string;
	    tooltip: string;
	
	    static createFrom(source: any = {}) {
	        return new TrayContent(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.icon = source["icon"];
	        this.title = source["title"];
	        this.tooltip = source["tooltip"];
	    }
	}

}

export namespace cdn {
	
	export class CustomDomain {
	    zoneId?: string;
	    zoneName?: string;
	    subdomain?: string;
	
	    static createFrom(source: any = {}) {
	        return new CustomDomain(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.zoneId = source["zoneId"];
	        this.zoneName = source["zoneName"];
	        this.subdomain = source["subdomain"];
	    }
	}
	export class Deployment {
	    nodeId: string;
	    scriptName: string;
	    workerHost: string;
	    backend: string;
	    // Go type: time
	    deployedAt: any;
	    customHost?: string;
	    customDomainId?: string;
	    customHostStatus?: string;
	    accountId?: string;
	    pathSecret?: string;
	    zoneId?: string;
	    routeId?: string;
	    dnsRecordId?: string;
	
	    static createFrom(source: any = {}) {
	        return new Deployment(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.nodeId = source["nodeId"];
	        this.scriptName = source["scriptName"];
	        this.workerHost = source["workerHost"];
	        this.backend = source["backend"];
	        this.deployedAt = this.convertValues(source["deployedAt"], null);
	        this.customHost = source["customHost"];
	        this.customDomainId = source["customDomainId"];
	        this.customHostStatus = source["customHostStatus"];
	        this.accountId = source["accountId"];
	        this.pathSecret = source["pathSecret"];
	        this.zoneId = source["zoneId"];
	        this.routeId = source["routeId"];
	        this.dnsRecordId = source["dnsRecordId"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class State {
	    status: string;
	    accountId?: string;
	    accountEmail?: string;
	    workersSubdomain?: string;
	    lastError?: string;
	    workersDevExample?: string;
	    deployments: Record<string, Deployment>;
	    customDomain?: CustomDomain;
	
	    static createFrom(source: any = {}) {
	        return new State(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.status = source["status"];
	        this.accountId = source["accountId"];
	        this.accountEmail = source["accountEmail"];
	        this.workersSubdomain = source["workersSubdomain"];
	        this.lastError = source["lastError"];
	        this.workersDevExample = source["workersDevExample"];
	        this.deployments = this.convertValues(source["deployments"], Deployment, true);
	        this.customDomain = this.convertValues(source["customDomain"], CustomDomain);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Zone {
	    id: string;
	    name: string;
	    status?: string;
	
	    static createFrom(source: any = {}) {
	        return new Zone(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.status = source["status"];
	    }
	}

}

export namespace cloud {
	
	export class CreateInstanceOptions {
	    label: string;
	    region: string;
	    plan: string;
	    osId: number;
	    sshKeyId: string;
	    host?: string;
	    extra?: Record<string, string>;
	
	    static createFrom(source: any = {}) {
	        return new CreateInstanceOptions(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.label = source["label"];
	        this.region = source["region"];
	        this.plan = source["plan"];
	        this.osId = source["osId"];
	        this.sshKeyId = source["sshKeyId"];
	        this.host = source["host"];
	        this.extra = source["extra"];
	    }
	}
	export class Instance {
	    id: string;
	    provider: string;
	    label: string;
	    status: string;
	    region: string;
	    plan: string;
	    osId: number;
	    ipv4: string;
	    ipv6: string;
	    port: number;
	    password: string;
	    // Go type: time
	    createdAt: any;
	    replacedInstanceId?: string;
	    ssPort?: number;
	    ssPassword?: string;
	    hysteriaPort?: number;
	    hysteriaPassword?: string;
	    hysteriaServerName?: string;
	    hysteriaInsecure?: boolean;
	    vlessPort?: number;
	    vlessUUID?: string;
	    vlessPublicKey?: string;
	    vlessShortId?: string;
	    vlessServerName?: string;
	    trojanPort?: number;
	    trojanPassword?: string;
	    trojanServerName?: string;
	    trojanInsecure?: boolean;
	    vlessRelayPort?: number;
	
	    static createFrom(source: any = {}) {
	        return new Instance(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.provider = source["provider"];
	        this.label = source["label"];
	        this.status = source["status"];
	        this.region = source["region"];
	        this.plan = source["plan"];
	        this.osId = source["osId"];
	        this.ipv4 = source["ipv4"];
	        this.ipv6 = source["ipv6"];
	        this.port = source["port"];
	        this.password = source["password"];
	        this.createdAt = this.convertValues(source["createdAt"], null);
	        this.replacedInstanceId = source["replacedInstanceId"];
	        this.ssPort = source["ssPort"];
	        this.ssPassword = source["ssPassword"];
	        this.hysteriaPort = source["hysteriaPort"];
	        this.hysteriaPassword = source["hysteriaPassword"];
	        this.hysteriaServerName = source["hysteriaServerName"];
	        this.hysteriaInsecure = source["hysteriaInsecure"];
	        this.vlessPort = source["vlessPort"];
	        this.vlessUUID = source["vlessUUID"];
	        this.vlessPublicKey = source["vlessPublicKey"];
	        this.vlessShortId = source["vlessShortId"];
	        this.vlessServerName = source["vlessServerName"];
	        this.trojanPort = source["trojanPort"];
	        this.trojanPassword = source["trojanPassword"];
	        this.trojanServerName = source["trojanServerName"];
	        this.trojanInsecure = source["trojanInsecure"];
	        this.vlessRelayPort = source["vlessRelayPort"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Plan {
	    id: string;
	    description?: string;
	    ram: number;
	    vcpus: number;
	    disk: number;
	    bandwidth: number;
	    monthlyCost?: number;
	    hourlyCost?: number;
	    type?: string;
	    locations?: string[];
	
	    static createFrom(source: any = {}) {
	        return new Plan(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.description = source["description"];
	        this.ram = source["ram"];
	        this.vcpus = source["vcpus"];
	        this.disk = source["disk"];
	        this.bandwidth = source["bandwidth"];
	        this.monthlyCost = source["monthlyCost"];
	        this.hourlyCost = source["hourlyCost"];
	        this.type = source["type"];
	        this.locations = source["locations"];
	    }
	}
	export class ProviderConfig {
	    provider: string;
	    apiKey?: string;
	    defaultRegion: string;
	    defaultPlan: string;
	    extra?: Record<string, string>;
	
	    static createFrom(source: any = {}) {
	        return new ProviderConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.provider = source["provider"];
	        this.apiKey = source["apiKey"];
	        this.defaultRegion = source["defaultRegion"];
	        this.defaultPlan = source["defaultPlan"];
	        this.extra = source["extra"];
	    }
	}
	export class Region {
	    id: string;
	    city: string;
	    country: string;
	    continent: string;
	
	    static createFrom(source: any = {}) {
	        return new Region(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.city = source["city"];
	        this.country = source["country"];
	        this.continent = source["continent"];
	    }
	}

}

export namespace ssh {
	
	export class ServerInfo {
	    os: string;
	    arch: string;
	    memoryMB: number;
	
	    static createFrom(source: any = {}) {
	        return new ServerInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.os = source["os"];
	        this.arch = source["arch"];
	        this.memoryMB = source["memoryMB"];
	    }
	}

}

