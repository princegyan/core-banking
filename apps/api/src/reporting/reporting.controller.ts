import { Controller, Get, Param, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { ReportingService } from './reporting.service';
import { ReportQueryDto } from './dto/report-query.dto';

@Controller('reporting')
@UseGuards(AuthGuard, PermissionsGuard)
export class ReportingController {
  constructor(private readonly reportingService: ReportingService) {}

  @Get('account-statement/:accountId')
  @RequirePermissions('reporting.statements')
  async getAccountStatement(
    @CurrentUser() user: AuthenticatedUser,
    @Param('accountId') accountId: string,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateAccountStatement(
      user.tenantId,
      accountId,
      query.fromDate,
      query.toDate,
    );
  }

  @Get('trial-balance')
  @RequirePermissions('reporting.gl')
  async getTrialBalance(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateTrialBalance(
      user.tenantId,
      query.asOfDate,
    );
  }

  @Get('general-ledger/:accountCode')
  @RequirePermissions('reporting.gl')
  async getGlReport(
    @CurrentUser() user: AuthenticatedUser,
    @Param('accountCode') accountCode: string,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateGlReport(
      user.tenantId,
      accountCode,
      query.fromDate,
      query.toDate,
    );
  }

  @Get('cash-position')
  @RequirePermissions('reporting.management')
  async getCashPosition(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateCashPosition(
      user.tenantId,
      query.branchId,
    );
  }

  @Get('daily-transactions')
  @RequirePermissions('reporting.management')
  async getDailyTransactions(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateDailyTransactionReport(
      user.tenantId,
      query.businessDate,
    );
  }

  @Get('income')
  @RequirePermissions('reporting.management')
  async getIncomeReport(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ReportQueryDto,
  ) {
    return this.reportingService.generateIncomeReport(
      user.tenantId,
      query.fromDate,
      query.toDate,
    );
  }
}
