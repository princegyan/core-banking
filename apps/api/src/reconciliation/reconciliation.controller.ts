import { Controller, Post, Get, Patch, Param, Body, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { ReconciliationService } from './reconciliation.service';
import { RunReconciliationDto, ResolveExceptionDto, CreateSuspenseDto, ClearSuspenseDto } from './dto/run-reconciliation.dto';

@Controller('reconciliation')
@UseGuards(AuthGuard, PermissionsGuard)
export class ReconciliationController {
  constructor(private readonly reconciliationService: ReconciliationService) {}

  @Post('gl-customer')
  @RequirePermissions('reconciliation.execute')
  async runGlCustomerReconciliation(
    @CurrentUser() user: AuthenticatedUser,
  ) {
    return this.reconciliationService.runGlCustomerReconciliation(user.tenantId, user.id);
  }

  @Post('cash')
  @RequirePermissions('reconciliation.execute')
  async runCashPositionReconciliation(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: RunReconciliationDto,
  ) {
    return this.reconciliationService.runCashPositionReconciliation(user.tenantId, dto.branchId, user.id);
  }

  @Post('ledger-balance')
  @RequirePermissions('reconciliation.execute')
  async runLedgerBalanceReconciliation(
    @CurrentUser() user: AuthenticatedUser,
  ) {
    return this.reconciliationService.runLedgerBalanceReconciliation(user.tenantId, user.id);
  }

  @Get('runs')
  @RequirePermissions('reconciliation.read')
  async getRuns(
    @CurrentUser() user: AuthenticatedUser,
  ) {
    return this.reconciliationService.getRuns(user.tenantId);
  }

  @Get('runs/:id')
  @RequirePermissions('reconciliation.read')
  async getRunById(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
  ) {
    return this.reconciliationService.getRunById(user.tenantId, id);
  }

  @Get('exceptions')
  @RequirePermissions('reconciliation.read')
  async getExceptions(
    @CurrentUser() user: AuthenticatedUser,
  ) {
    return this.reconciliationService.getExceptions(user.tenantId);
  }

  @Patch('exceptions/:id')
  @RequirePermissions('reconciliation.resolve')
  async resolveException(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body() dto: ResolveExceptionDto,
  ) {
    return this.reconciliationService.resolveException(user.tenantId, id, user.id, dto);
  }

  @Post('suspense')
  @RequirePermissions('reconciliation.execute')
  async createSuspenseEntry(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: CreateSuspenseDto,
  ) {
    return this.reconciliationService.createSuspenseEntry(user.tenantId, dto);
  }

  @Patch('suspense/:id/clear')
  @RequirePermissions('reconciliation.resolve')
  async clearSuspenseEntry(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body() dto: ClearSuspenseDto,
  ) {
    return this.reconciliationService.clearSuspenseEntry(user.tenantId, id, user.id, dto);
  }
}
