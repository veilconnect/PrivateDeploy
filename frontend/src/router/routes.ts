import { type RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'Workbench',
    component: () => import('@/views/WorkbenchView/index.vue'),
    meta: {
      name: 'router.workbench',
      icon: 'overview',
    },
  },
  {
    path: '/settings',
    name: 'Settings',
    component: () => import('@/views/SettingsView/index.vue'),
    meta: {
      name: 'router.settings',
      icon: 'settings2',
      hidden: false,
    },
  },
  {
    path: '/wizard',
    name: 'Wizard',
    component: () => import('@/views/WizardView/index.vue'),
    meta: {
      name: 'router.wizard',
      icon: 'sparkle',
      hidden: true,
    },
  },
  {
    path: '/profiles',
    redirect: () => ({ name: 'Settings', query: { tab: 'profiles' } }),
  },
  {
    path: '/subscriptions',
    redirect: () => ({ name: 'Settings', query: { tab: 'cloud' } }),
  },
  {
    path: '/rulesets',
    redirect: () => ({ name: 'Settings', query: { tab: 'rulesets' } }),
  },
  {
    path: '/scheduledtasks',
    redirect: () => ({ name: 'Settings' }),
  },
]

export default routes
