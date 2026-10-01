import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { OnboardTenantDto } from './dto/onboard-tenant.dto';
import { SuspendTenantDto } from './dto/suspend-tenant.dto';
import { UpdateSubscriptionDto } from './dto/update-subscription.dto';
import { CreatePlanDto } from './dto/create-plan.dto';

@Injectable()
export class SaasService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async onboardTenant(superAdminId: string, dto: OnboardTenantDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('onboard_new_tenant', {
      p_name: dto.name,
      p_slug: dto.slug.toLowerCase().trim(),
      p_country_code: dto.countryCode ?? 'GH',
      p_default_currency: dto.defaultCurrency ?? 'GHS',
      p_admin_email: dto.adminEmail,
      p_admin_first_name: dto.adminFirstName,
      p_admin_last_name: dto.adminLastName,
      p_plan_code: dto.planCode ?? 'STARTER',
      p_super_admin_id: superAdminId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async listTenants() {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('tenants')
      .select(`
        id,
        name,
        slug,
        status,
        country_code,
        default_currency,
        created_at,
        updated_at,
        tenant_subscriptions (
          id,
          status,
          billing_cycle,
          current_period_start,
          current_period_end,
          auto_renew,
          subscription_plans (
            id,
            plan_code,
            name,
            tier,
            monthly_fee
          )
        )
      `)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getTenant(tenantId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('tenants')
      .select(`
        id,
        name,
        slug,
        status,
        country_code,
        default_currency,
        created_at,
        updated_at,
        institutions (
          id,
          name,
          code
        ),
        branches (
          id,
          code,
          name,
          is_active
        ),
        tenant_subscriptions (
          id,
          status,
          billing_cycle,
          current_period_start,
          current_period_end,
          subscription_plans (
            id,
            plan_code,
            name,
            tier,
            monthly_fee,
            max_accounts,
            max_users,
            max_branches,
            features
          )
        ),
        tenant_configurations (
          config_key,
          config_value
        ),
        tenant_limits (
          limit_type,
          limit_value,
          current_value
        )
      `)
      .eq('id', tenantId)
      .maybeSingle();

    if (error) {
      throw new BadRequestException(error.message);
    }

    if (!data) {
      throw new NotFoundException('Tenant not found');
    }

    return data;
  }

  async suspendTenant(superAdminId: string, tenantId: string, dto: SuspendTenantDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('suspend_tenant', {
      p_tenant_id: tenantId,
      p_reason: dto.reason,
      p_super_admin_id: superAdminId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async reactivateTenant(superAdminId: string, tenantId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('reactivate_tenant', {
      p_tenant_id: tenantId,
      p_super_admin_id: superAdminId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async updateSubscription(superAdminId: string, tenantId: string, dto: UpdateSubscriptionDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('update_tenant_subscription', {
      p_tenant_id: tenantId,
      p_plan_code: dto.planCode,
      p_super_admin_id: superAdminId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async listPlans() {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('subscription_plans')
      .select('*')
      .eq('is_active', true)
      .order('monthly_fee', { ascending: true });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async createPlan(dto: CreatePlanDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('subscription_plans')
      .insert({
        plan_code: dto.planCode.toUpperCase().trim(),
        name: dto.name,
        tier: dto.tier,
        monthly_fee: dto.monthlyFee,
        max_accounts: dto.maxAccounts,
        max_users: dto.maxUsers,
        max_branches: dto.maxBranches,
        max_monthly_transactions: dto.maxMonthlyTransactions,
        features: dto.features ?? {},
      })
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getPlatformMetrics(superAdminId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('get_platform_metrics', {
      p_super_admin_id: superAdminId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getPlatformAuditLogs() {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('platform_audit_logs')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(100);

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }
}
