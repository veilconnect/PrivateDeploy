import { type RouteRecordRaw } from 'vue-router'

import CloudView from '@/views/CloudView/index.vue'
import HomeView from '@/views/HomeView/index.vue'
import ProfilesView from '@/views/ProfilesView/index.vue'
import RulesetsView from '@/views/RulesetsView/index.vue'
import ScheduledTasksView from '@/views/ScheduledTasksView/index.vue'
import SettingsView from '@/views/SettingsView/index.vue'
import WizardView from '@/views/WizardView/index.vue'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'Overview',
    component: HomeView,
    meta: {
      name: 'router.overview',
      icon: 'overview',
    },
  },
  {
    path: '/profiles',
    name: 'Profiles',
    component: ProfilesView,
    meta: {
      name: 'router.profiles',
      icon: 'profiles',
    },
  },
  {
    path: '/subscriptions',
    name: 'Deploy',
    component: CloudView,
    meta: {
      name: 'router.subscriptions',
      icon: 'sparkle',
    },
  },
  {
    path: '/rulesets',
    name: 'Rulesets',
    component: RulesetsView,
    meta: {
      name: 'router.rulesets',
      icon: 'rulesets',
    },
  },
  {
    path: '/scheduledtasks',
    name: 'ScheduledTasks',
    component: ScheduledTasksView,
    meta: {
      name: 'router.scheduledtasks',
      icon: 'scheduledTasks',
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
    path: '/settings',
    name: 'Settings',
    component: SettingsView,
    meta: {
      name: 'router.settings',
      icon: 'settings2',
      hidden: false,
    },
  },
]

export default routes
