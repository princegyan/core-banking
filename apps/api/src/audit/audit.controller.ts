import {
  Controller,
  Get,
  Post,
  Body,
  Query,
  UseGuards,
} from '@nestjs/common';

import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { AuditService } from './audit.service';
import { QueryAuditLogDto } from './dto/query-audit-log.dto';

@Controller('audit')
@UseGuards(AuthGuard, PermissionsGuard)
export class AuditController {
  constructor(private readonly auditService: AuditService) {}

  @Get('logs')
  @RequirePermissions('audit.read')
  async getAuditLogs(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: QueryAuditLogDto,
  ) {
    return this.auditService.queryAuditTrail(
      user.tenantId,
      query,
    );
  }

  @Get('access-logs')
  @RequirePermissions('audit.read')
  async getAccessLogs(
    @CurrentUser() user: AuthenticatedUser,
    @Query('userId') userId?: string,
    @Query('fromDate') fromDate?: string,
    @Query('toDate') toDate?: string,
  ) {
    return this.auditService.getAccessLogs(
      user.tenantId,
      userId,
      fromDate,
      toDate,
    );
  }

  @Get('login-history')
  @RequirePermissions('audit.read')
  async getLoginHistory(
    @CurrentUser() user: AuthenticatedUser,
    @Query('userId') userId?: string,
    @Query('email') email?: string,
    @Query('fromDate') fromDate?: string,
    @Query('toDate') toDate?: string,
  ) {
    return this.auditService.getLoginHistory(
      user.tenantId,
      userId,
      email,
      fromDate,
      toDate,
    );
  }

  @Get('compliance-report')
  @RequirePermissions('audit.read')
  async getComplianceReport(
    @CurrentUser() user: AuthenticatedUser,
    @Query('fromDate') fromDate: string,
    @Query('toDate') toDate: string,
  ) {
    return this.auditService.generateComplianceReport(
      user.tenantId,
      fromDate,
      toDate,
    );
  }

  @Post('retention-policy')
  @RequirePermissions('audit.manage')
  async configureRetentionPolicy(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: { logType: string; retentionDays: number },
  ) {
    return this.auditService.configureRetentionPolicy(
      user.tenantId,
      dto.logType,
      dto.retentionDays,
    );
  }

  @Post('apply-retention')
  @RequirePermissions('audit.manage')
  async applyRetention(
    @CurrentUser() user: AuthenticatedUser,
  ) {
    return this.auditService.applyRetentionPolicy(
      user.tenantId,
    );
  }
}
