import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { CreateUserDto } from './dto/create-user.dto';
import { SetUserLimitDto } from './dto/set-user-limit.dto';
import { ConfigureApprovalPolicyDto } from './dto/configure-approval-policy.dto';

@Injectable()
export class AdminService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async createUser(tenantId: string, userId: string, dto: CreateUserDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('admin_create_user', {
      p_tenant_id: tenantId,
      p_email: dto.email,
      p_first_name: dto.firstName,
      p_last_name: dto.lastName,
      p_phone: dto.phone ?? null,
      p_branch_id: dto.branchId ?? null,
      p_created_by: userId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async findAllUsers(tenantId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('users')
      .select(`
        id,
        email,
        first_name,
        last_name,
        phone_number,
        branch_id,
        is_active,
        created_at,
        updated_at
      `)
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async findOneUser(tenantId: string, id: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('users')
      .select(`
        id,
        email,
        first_name,
        last_name,
        phone_number,
        branch_id,
        is_active,
        created_at,
        updated_at,
        user_roles (
          role_id,
          roles (
            name,
            description
          )
        )
      `)
      .eq('id', id)
      .eq('tenant_id', tenantId)
      .maybeSingle();

    if (error) {
      throw new BadRequestException(error.message);
    }

    if (!data) {
      throw new NotFoundException('User not found');
    }

    return data;
  }

  async toggleUserActive(tenantId: string, id: string, isActive: boolean, performedBy: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('admin_toggle_user_active', {
      p_tenant_id: tenantId,
      p_user_id: id,
      p_is_active: isActive,
      p_performed_by: performedBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async assignRole(tenantId: string, userId: string, roleId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('admin_assign_role', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_role_id: roleId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async removeRole(tenantId: string, userId: string, roleId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('admin_remove_role', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_role_id: roleId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async assignBranch(tenantId: string, userId: string, branchId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('admin_assign_branch', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_branch_id: branchId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async setLimit(tenantId: string, userId: string, dto: SetUserLimitDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('set_user_limit', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_limit_type: dto.limitType,
      p_max_amount: dto.maxAmount,
      p_currency: dto.currency,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getUserLimits(tenantId: string, userId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('user_limits')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('user_id', userId)
      .eq('is_active', true);

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async checkLimit(tenantId: string, userId: string, limitType: string, amount: number) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('check_user_limit', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_limit_type: limitType,
      p_amount: amount,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async configurePolicy(tenantId: string, dto: ConfigureApprovalPolicyDto) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('configure_approval_policy', {
      p_tenant_id: tenantId,
      p_policy_name: dto.policyName,
      p_entity_type: dto.entityType,
      p_action_type: dto.actionType,
      p_min_amount: dto.minAmount,
      p_max_amount: dto.maxAmount ?? null,
      p_required_approvers: dto.requiredApprovers,
      p_approver_role_id: dto.approverRoleId ?? null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getPolicies(tenantId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('approval_policies')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async setBranchControl(tenantId: string, branchId: string, controlType: string, controlValue: any) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('branch_controls')
      .upsert({
        tenant_id: tenantId,
        branch_id: branchId,
        control_type: controlType,
        control_value: controlValue,
        is_active: true
      }, { onConflict: 'tenant_id,branch_id,control_type' })
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getBranchControls(tenantId: string, branchId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('branch_controls')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('branch_id', branchId)
      .eq('is_active', true);

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }
}
