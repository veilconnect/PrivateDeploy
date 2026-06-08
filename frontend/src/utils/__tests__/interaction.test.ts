import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  h: vi.fn((component, props = {}) => ({
    appContext: undefined,
    component: undefined,
    props,
    type: component,
  })),
  logError: vi.fn(),
  modalApi: {
    close: vi.fn(),
    open: vi.fn(),
  },
  nextTick: vi.fn((callback?: () => void) => {
    callback?.()
    return Promise.resolve()
  }),
  render: vi.fn((vnode, container) => {
    if (vnode) {
      vnode.component = { props: vnode.props }
      ;(container as HTMLElement & { __vnode?: unknown }).__vnode = vnode
    }
  }),
  sampleID: vi.fn(),
  useModal: vi.fn(),
}))

vi.mock('vue', () => ({
  h: mocks.h,
  nextTick: mocks.nextTick,
  render: mocks.render,
}))

vi.mock('@/lang', () => ({
  default: {
    global: {
      t: (key: string) => `t:${key}`,
    },
  },
}))

vi.mock('@/utils', () => ({
  APP_TITLE: 'PrivateDeploy',
  logError: mocks.logError,
  sampleID: mocks.sampleID,
}))

vi.mock('@/components/Confirm/index.vue', () => ({
  default: { name: 'ConfirmComp' },
}))

vi.mock('@/components/Message/index.vue', () => ({
  default: { name: 'MessageComp' },
}))

vi.mock('@/components/Modal', () => ({
  useModal: mocks.useModal,
}))

vi.mock('@/components/Picker/index.vue', () => ({
  default: { name: 'PickerComp' },
}))

vi.mock('@/components/Prompt/index.vue', () => ({
  default: { name: 'PromptComp' },
}))

import {
  alert,
  confirm,
  message,
  modal,
  picker,
  prompt,
} from '../interaction'

const appContext = { app: 'test-app' }

const setAppContext = () => {
  ;(window as unknown as { appInstance: { _context: unknown } }).appInstance = {
    _context: appContext,
  }
}

const lastRenderedVNode = () => {
  const calls = mocks.render.mock.calls.filter(([vnode]) => vnode)
  return calls[calls.length - 1]?.[0]
}

const lastRenderContainer = () => {
  const calls = mocks.render.mock.calls.filter(([vnode]) => vnode)
  return calls[calls.length - 1]?.[1] as HTMLElement
}

describe('interaction utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useRealTimers()
    setAppContext()

    Object.keys(message.instances).forEach((id) => message.destroy(id))
    document.body.innerHTML = ''
    message.container.innerHTML = ''
    document.body.appendChild(message.container)

    mocks.sampleID.mockReturnValue('toast-1')
    mocks.useModal.mockReturnValue([{ name: 'ModalComp' }, mocks.modalApi])
  })

  it('creates, updates, logs, and destroys toast messages', () => {
    vi.useFakeTimers()
    const onClose = vi.fn()

    const toast = message.error('errors.failed', 1000, onClose)
    const instance = message.instances[toast.id]

    expect(toast.id).toBe('toast-1')
    expect(mocks.logError).toHaveBeenCalledWith('[Toast]', 't:errors.failed')
    expect(message.container.contains(instance.dom)).toBe(true)
    expect(instance.vnode.appContext).toBe(appContext)
    expect(mocks.render).toHaveBeenCalledWith(instance.vnode, instance.dom)

    toast.update('Updated', 'success')
    expect(instance.vnode.component!.props).toMatchObject({
      content: 'Updated',
      icon: 'success',
    })

    toast.info('Info')
    toast.warn('Warn')
    toast.error('Error')
    toast.success('Success')
    expect(instance.vnode.component!.props).toMatchObject({
      content: 'Success',
      icon: 'success',
    })

    instance.vnode.component!.props.onClose()

    expect(onClose).toHaveBeenCalled()
    expect(message.instances[toast.id]).toBeUndefined()
    expect(instance.dom.isConnected).toBe(false)

    message.update('missing', 'noop')
    message.destroy('missing')
    vi.useRealTimers()
  })

  it('resolves and rejects prompt, alert, confirm, and picker overlays', async () => {
    const promptPromise = prompt<number>('Enter port', '7890', { placeholder: 'Port' })
    let vnode = lastRenderedVNode()
    const container = lastRenderContainer()

    expect(vnode.props).toMatchObject({
      initialValue: '7890',
      props: { placeholder: 'Port' },
      title: 'Enter port',
    })
    vnode.props.onSubmit(7890)
    vnode.props.onFinish()
    await expect(promptPromise).resolves.toBe(7890)
    expect(container.isConnected).toBe(false)

    const alertPromise = alert('Heads up', 'Read this')
    vnode = lastRenderedVNode()
    expect(vnode.props).toMatchObject({
      cancel: false,
      message: 'Read this',
      title: 'Heads up',
    })
    vnode.props.onConfirm(true)
    await expect(alertPromise).resolves.toBe(true)

    const confirmPromise = confirm('Delete', 'Remove item?')
    vnode = lastRenderedVNode()
    expect(vnode.props.cancel).toBe(true)
    vnode.props.onCancel()
    await expect(confirmPromise).rejects.toBe('t:common.canceled')

    const singlePromise = picker.single('Region', [{ label: 'Tokyo', value: 'nrt' }], ['nrt'])
    vnode = lastRenderedVNode()
    expect(vnode.props).toMatchObject({
      initialValue: ['nrt'],
      title: 'Region',
      type: 'single',
    })
    vnode.props.onConfirm('nrt')
    await expect(singlePromise).resolves.toBe('nrt')

    const multiPromise = picker.multi('Regions', [{ label: 'Tokyo', value: 'nrt' }], [])
    vnode = lastRenderedVNode()
    vnode.props.onCancel()
    await expect(multiPromise).rejects.toBe('t:common.canceled')
  })

  it('creates modal APIs and destroys their rendered container on next tick', async () => {
    const api = modal({ title: 'Settings' }, { default: () => [] })
    const container = lastRenderContainer()

    expect(mocks.useModal).toHaveBeenCalledWith({ title: 'Settings' }, { default: expect.any(Function) })
    expect(api.open).toBe(mocks.modalApi.open)
    expect(container.isConnected).toBe(true)

    api.destroy()
    await Promise.resolve()

    expect(mocks.modalApi.close).toHaveBeenCalled()
    expect(mocks.nextTick).toHaveBeenCalledWith(expect.any(Function))
    expect(mocks.render).toHaveBeenCalledWith(null, container)
    expect(container.isConnected).toBe(false)
  })
})
