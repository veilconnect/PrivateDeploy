import { type RouteRecordRaw } from 'vue-router'

import SettingsView from '@/views/SettingsView/index.vue'
import WizardView from '@/views/WizardView/index.vue'
import WorkbenchView from '@/views/WorkbenchView/index.vue'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'Workbench',
    component: WorkbenchView,
    meta: {
      name: 'router.workbench',
      icon: 'overview',
    },
  },
  {
    path: '/settings',
    name: 'Settings',
    component: SettingsView,
    meta: {
      name: 'router.settings',
      icon: 'settings2',
      hidden: false,
    },
  },
  {
    path: '/wizard',
    name: 'Wizard',
    component: WizardView,
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
