// Mock for @wails/go/bridge/App used in tests
// All bridge functions return a resolved FlagResult
const mockResult = () => Promise.resolve({ Flag: true, Data: '{}' })

export const GetCloudConfig = mockResult
export const SaveCloudConfig = mockResult
export const ListCloudProviders = mockResult
export const GetCloudProvider = mockResult
export const GetCloudProviderAccountStatus = mockResult
export const GetCloudProviderAccountStatusTyped = mockResult
export const SetCloudProvider = mockResult
export const ListCloudInstances = mockResult
export const CreateCloudInstance = mockResult
export const CreateMultipleCloudInstances = mockResult
export const DestroyCloudInstance = mockResult
export const RepairCloudInstance = mockResult
export const RepairCloudInstanceTyped = mockResult
export const ListCloudRegions = mockResult
export const ListCloudPlans = mockResult
export const ListCloudAvailability = mockResult
export const ReadFile = mockResult
export const WriteFile = mockResult
export const RemoveFile = mockResult
export const TestConnectivity = mockResult
export const StartHealthMonitor = mockResult
export const StopHealthMonitor = mockResult
export const GetHealthStatus = mockResult
export const GetEnv = mockResult
export const RestartCore = mockResult
export const StartCore = mockResult
export const StopCore = mockResult

// Catch-all proxy for any other functions
export default new Proxy({}, {
  get: (_target, _prop) => mockResult,
})
