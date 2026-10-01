import { Controller, Get, Post, Patch, Body, Param, UseGuards } from '@nestjs/common';
import { NotificationsService } from './notifications.service';
import { CreateTemplateDto } from './dto/create-template.dto';
import { QueueNotificationDto } from './dto/queue-notification.dto';
import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

@Controller('notifications')
@UseGuards(AuthGuard, PermissionsGuard)
export class NotificationsController {
  constructor(private readonly notificationsService: NotificationsService) {}

  @Post('templates')
  @RequirePermissions('notifications.manage')
  async createTemplate(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: CreateTemplateDto,
  ) {
    return this.notificationsService.createTemplate(user.tenantId, dto);
  }

  @Get('templates')
  @RequirePermissions('notifications.read')
  async getTemplates(@CurrentUser() user: AuthenticatedUser) {
    return this.notificationsService.getTemplates(user.tenantId);
  }

  @Patch('templates/:id')
  @RequirePermissions('notifications.manage')
  async updateTemplate(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body() dto: Partial<CreateTemplateDto>,
  ) {
    return this.notificationsService.updateTemplate(user.tenantId, id, dto);
  }

  @Post('send')
  @RequirePermissions('notifications.send')
  async queueNotification(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: QueueNotificationDto,
  ) {
    return this.notificationsService.queueNotification(user.tenantId, dto);
  }

  @Post('process-queue')
  @RequirePermissions('notifications.manage')
  async processQueue(
    @CurrentUser() user: AuthenticatedUser,
    @Body('batchSize') batchSize?: number,
  ) {
    return this.notificationsService.processQueue(user.tenantId, batchSize);
  }

  @Get('history/:recipientId')
  @RequirePermissions('notifications.read')
  async getHistory(
    @CurrentUser() user: AuthenticatedUser,
    @Param('recipientId') recipientId: string,
  ) {
    return this.notificationsService.getHistory(user.tenantId, recipientId);
  }

  @Post('preferences')
  @RequirePermissions('notifications.manage')
  async updatePreferences(
    @CurrentUser() user: AuthenticatedUser,
    @Body('customerId') customerId: string,
    @Body('channel') channel: string,
    @Body('isEnabled') isEnabled: boolean,
  ) {
    return this.notificationsService.updatePreferences(user.tenantId, customerId, channel, isEnabled);
  }

  @Get('preferences/:customerId')
  @RequirePermissions('notifications.read')
  async getPreferences(
    @CurrentUser() user: AuthenticatedUser,
    @Param('customerId') customerId: string,
  ) {
    return this.notificationsService.getPreferences(user.tenantId, customerId);
  }
}
