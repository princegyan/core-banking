import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';
import { SuperAdminGuard } from './guards/super-admin.guard';
import { SaasService } from './saas.service';
import { OnboardTenantDto } from './dto/onboard-tenant.dto';
import { SuspendTenantDto } from './dto/suspend-tenant.dto';
import { UpdateSubscriptionDto } from './dto/update-subscription.dto';
import { CreatePlanDto } from './dto/create-plan.dto';

@Controller('saas')
@UseGuards(AuthGuard, SuperAdminGuard)
export class SaasController {
  constructor(private readonly saasService: SaasService) {}

  @Post('tenants/onboard')
  async onboardTenant(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: OnboardTenantDto,
  ) {
    return this.saasService.onboardTenant(user.id, dto);
  }

  @Get('tenants')
  async listTenants() {
    return this.saasService.listTenants();
  }

  @Get('tenants/:id')
  async getTenant(@Param('id') tenantId: string) {
    return this.saasService.getTenant(tenantId);
  }

  @Patch('tenants/:id/suspend')
  async suspendTenant(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') tenantId: string,
    @Body() dto: SuspendTenantDto,
  ) {
    return this.saasService.suspendTenant(user.id, tenantId, dto);
  }

  @Patch('tenants/:id/reactivate')
  async reactivateTenant(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') tenantId: string,
  ) {
    return this.saasService.reactivateTenant(user.id, tenantId);
  }

  @Patch('tenants/:id/subscription')
  async updateSubscription(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') tenantId: string,
    @Body() dto: UpdateSubscriptionDto,
  ) {
    return this.saasService.updateSubscription(user.id, tenantId, dto);
  }

  @Get('plans')
  async listPlans() {
    return this.saasService.listPlans();
  }

  @Post('plans')
  async createPlan(@Body() dto: CreatePlanDto) {
    return this.saasService.createPlan(dto);
  }

  @Get('metrics')
  async getPlatformMetrics(@CurrentUser() user: AuthenticatedUser) {
    return this.saasService.getPlatformMetrics(user.id);
  }

  @Get('audit-logs')
  async getPlatformAuditLogs() {
    return this.saasService.getPlatformAuditLogs();
  }
}
