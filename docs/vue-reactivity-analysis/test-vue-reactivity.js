/**
 * Vue 3 响应式系统测试脚本
 * 用于验证浅拷贝 vs 深拷贝在乐观UI更新中的行为差异
 *
 * 运行方式：node test-vue-reactivity.js
 */

// 模拟 Vue 3 的 ref
class RefImpl {
  constructor(value) {
    this._value = value
    this._updateCount = 0
    this._listeners = []
  }

  get value() {
    return this._value
  }

  set value(newValue) {
    const oldValue = this._value

    // Vue 的变化检测：检查引用是否变化
    const hasChanged = newValue !== oldValue

    console.log('\n[Vue 响应式检测]')
    console.log('  顶层对象引用变化:', hasChanged ? '是 ✅' : '否 ❌')

    if (hasChanged) {
      // 检查内部对象引用
      if (typeof newValue === 'object' && typeof oldValue === 'object') {
        const keys = Object.keys(newValue)
        let innerRefChanged = false

        for (const key of keys) {
          if (oldValue[key] && newValue[key] !== oldValue[key]) {
            innerRefChanged = true
            console.log(`  内部对象 "${key}" 引用变化: 是 ✅`)
          } else if (oldValue[key]) {
            console.log(`  内部对象 "${key}" 引用变化: 否 ❌ (可能导致更新失败)`)
          }
        }
      }

      this._value = newValue
      this._updateCount++
      console.log(`  -> 触发响应式更新 #${this._updateCount}`)

      // 触发监听器
      this._listeners.forEach(listener => listener(newValue, oldValue))
    } else {
      console.log('  -> 跳过更新（引用未变）')
    }
  }

  watch(callback) {
    this._listeners.push(callback)
  }

  getUpdateCount() {
    return this._updateCount
  }
}

const ref = (value) => new RefImpl(value)

// 深拷贝函数
const deepClone = (obj) => JSON.parse(JSON.stringify(obj))

// 创建测试数据
const createTestData = () => ({
  'group-selector': {
    name: 'group-selector',
    type: 'Selector',
    now: 'proxy-1',
    all: ['proxy-1', 'proxy-2', 'proxy-3'],
  },
  'group-urltest': {
    name: 'group-urltest',
    type: 'URLTest',
    now: 'proxy-2',
    all: ['proxy-1', 'proxy-2', 'proxy-3'],
  },
  'proxy-2': {
    name: 'proxy-2',
    type: 'Subscription',
    now: '',
    all: [],
  }
})

console.log('='.repeat(80))
console.log('Vue 3 响应式系统测试：浅拷贝 vs 深拷贝')
console.log('='.repeat(80))

// ==================== 测试 1：浅拷贝（问题实现）====================
console.log('\n\n' + '█'.repeat(80))
console.log('测试 1：浅拷贝实现（当前有问题的代码）')
console.log('█'.repeat(80))

const proxiesShallow = ref(createTestData())

proxiesShallow.watch((newVal, oldVal) => {
  console.log('\n[Watch 回调触发]')
  console.log('  新值keys:', Object.keys(newVal))
  console.log('  旧值keys:', Object.keys(oldVal))
})

console.log('\n初始数据:')
console.log(JSON.stringify(proxiesShallow.value, null, 2))

console.log('\n\n--- 执行浅拷贝删除操作 ---')

const removeProxyFromGroups_Shallow = (subscriptionId) => {
  console.log(`\n[removeProxyFromGroups_Shallow] 删除 "${subscriptionId}"`)

  const original = proxiesShallow.value
  const updated = { ...proxiesShallow.value }  // 浅拷贝

  console.log('\n[浅拷贝分析]')
  console.log('  原始对象:', original)
  console.log('  拷贝对象:', updated)
  console.log('  顶层对象相同?', original === updated ? '是 ❌' : '否 ✅')

  // 检查内部引用
  if (original['group-selector'] && updated['group-selector']) {
    const same = original['group-selector'] === updated['group-selector']
    console.log('  group-selector 相同?', same ? '是 ❌ (问题!)' : '否 ✅')
    console.log('  group-selector.all 相同?',
      original['group-selector'].all === updated['group-selector'].all ? '是 ❌' : '否 ✅')
  }

  console.log('\n[修改嵌套对象]')
  Object.keys(updated).forEach((groupName) => {
    const group = updated[groupName]
    if (group.all && Array.isArray(group.all)) {
      const oldLength = group.all.length
      console.log(`  修改前 ${groupName}.all:`, group.all)

      // 直接修改（这里修改的是原始对象的引用！）
      group.all = group.all.filter((proxyName) => proxyName !== subscriptionId)

      console.log(`  修改后 ${groupName}.all:`, group.all)
      console.log(`  长度变化: ${oldLength} -> ${group.all.length}`)

      if (group.now === subscriptionId && group.all.length > 0) {
        group.now = group.all[0]
      }
    }
  })

  delete updated[subscriptionId]
  console.log('\n[删除顶层代理]', subscriptionId)

  console.log('\n[重新赋值 proxies.value]')
  proxiesShallow.value = updated
}

removeProxyFromGroups_Shallow('proxy-2')

console.log('\n\n--- 操作后数据 ---')
console.log(JSON.stringify(proxiesShallow.value, null, 2))
console.log('\n总响应式更新次数:', proxiesShallow.getUpdateCount())
console.log('\n❌ 问题：虽然触发了更新，但由于修改了共享引用，可能导致 Vue 的细粒度更新检测失效')

// ==================== 测试 2：深拷贝（正确实现）====================
console.log('\n\n' + '█'.repeat(80))
console.log('测试 2：深拷贝实现（正确的解决方案）')
console.log('█'.repeat(80))

const proxiesDeep = ref(createTestData())

proxiesDeep.watch((newVal, oldVal) => {
  console.log('\n[Watch 回调触发]')
  console.log('  新值keys:', Object.keys(newVal))
  console.log('  旧值keys:', Object.keys(oldVal))
})

console.log('\n初始数据:')
console.log(JSON.stringify(proxiesDeep.value, null, 2))

console.log('\n\n--- 执行深拷贝删除操作 ---')

const removeProxyFromGroups_Deep = (subscriptionId) => {
  console.log(`\n[removeProxyFromGroups_Deep] 删除 "${subscriptionId}"`)

  const original = proxiesDeep.value
  const updated = deepClone(proxiesDeep.value)  // 深拷贝

  console.log('\n[深拷贝分析]')
  console.log('  顶层对象相同?', original === updated ? '是 ❌' : '否 ✅')

  // 检查内部引用
  if (original['group-selector'] && updated['group-selector']) {
    const same = original['group-selector'] === updated['group-selector']
    console.log('  group-selector 相同?', same ? '是 ❌' : '否 ✅ (完全独立)')
    console.log('  group-selector.all 相同?',
      original['group-selector'].all === updated['group-selector'].all ? '是 ❌' : '否 ✅ (完全独立)')
  }

  console.log('\n[修改嵌套对象]')
  Object.keys(updated).forEach((groupName) => {
    const group = updated[groupName]
    if (group.all && Array.isArray(group.all)) {
      const oldLength = group.all.length
      console.log(`  修改前 ${groupName}.all:`, group.all)

      // 修改的是全新的对象，不影响原始对象
      group.all = group.all.filter((proxyName) => proxyName !== subscriptionId)

      console.log(`  修改后 ${groupName}.all:`, group.all)
      console.log(`  长度变化: ${oldLength} -> ${group.all.length}`)

      if (group.now === subscriptionId && group.all.length > 0) {
        group.now = group.all[0]
      }
    }
  })

  delete updated[subscriptionId]
  console.log('\n[删除顶层代理]', subscriptionId)

  console.log('\n[重新赋值 proxies.value]')
  proxiesDeep.value = updated
}

removeProxyFromGroups_Deep('proxy-2')

console.log('\n\n--- 操作后数据 ---')
console.log(JSON.stringify(proxiesDeep.value, null, 2))
console.log('\n总响应式更新次数:', proxiesDeep.getUpdateCount())
console.log('\n✅ 成功：所有对象都是全新的引用，Vue 的响应式系统能正确追踪所有变化')

// ==================== 测试 3：引用共享验证 ====================
console.log('\n\n' + '█'.repeat(80))
console.log('测试 3：验证浅拷贝的引用共享问题')
console.log('█'.repeat(80))

const original = {
  group1: {
    all: [1, 2, 3],
    nested: { value: 'original' }
  }
}

console.log('\n原始对象:', JSON.stringify(original, null, 2))

console.log('\n\n--- 浅拷贝测试 ---')
const shallow = { ...original }
console.log('shallow === original:', shallow === original)
console.log('shallow.group1 === original.group1:', shallow.group1 === original.group1, '❌ 共享引用!')

// 修改浅拷贝
shallow.group1.all.push(4)
console.log('\n修改 shallow.group1.all.push(4) 后:')
console.log('original.group1.all:', original.group1.all, '❌ 原始对象被污染!')
console.log('shallow.group1.all:', shallow.group1.all)

console.log('\n\n--- 深拷贝测试 ---')
const original2 = {
  group1: {
    all: [1, 2, 3],
    nested: { value: 'original' }
  }
}
const deep = deepClone(original2)
console.log('deep === original2:', deep === original2)
console.log('deep.group1 === original2.group1:', deep.group1 === original2.group1, '✅ 完全独立!')

// 修改深拷贝
deep.group1.all.push(4)
console.log('\n修改 deep.group1.all.push(4) 后:')
console.log('original2.group1.all:', original2.group1.all, '✅ 原始对象未受影响!')
console.log('deep.group1.all:', deep.group1.all)

// ==================== 总结 ====================
console.log('\n\n' + '='.repeat(80))
console.log('总结与建议')
console.log('='.repeat(80))

console.log(`
问题根源：
  1. 浅拷贝 { ...proxies.value } 只复制顶层对象
  2. 内部的 group 对象仍然是原始响应式对象的引用
  3. 修改 group.all 时，实际修改的是原始对象
  4. Vue 可能无法正确检测到这些变化

解决方案：
  ✅ 使用深拷贝 deepClone(proxies.value)
  ✅ 确保每次修改都创建全新的对象引用
  ✅ 避免引用共享导致的响应式失效

需要修改的文件：
  📁 ~/PrivateDeploy/frontend/src/stores/kernelApi.ts
     - 第723行: const updated = deepClone(proxies.value)
     - 第750行: const updated = deepClone(proxies.value)

修改前后对比：
  ❌ const updated = { ...proxies.value }
  ✅ const updated = deepClone(proxies.value)
`)

console.log('='.repeat(80))
console.log('测试完成！')
console.log('='.repeat(80))
