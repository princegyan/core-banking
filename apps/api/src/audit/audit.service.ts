import {
  BadRequestException,
  Injectable,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';
import { QueryAuditLogDto } from './dto/query-audit-log.dto';

@Injectable()
export class AuditService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async queryAuditTrail(
    tenantId: string,
    query: QueryAuditLogDto,
  ) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc(
      'query_audit_trail',
      {
        p_tenant_id: tenantId,
        p_entity_type: query.entityType ?? null,
        p_entity_id: query.entityId ?? null,
        p_user_id: query.userId ?? null,
        p_from_date: query.fromDate ?? null,
        p_to_date: query.toDate ?? null,
        p_limit: query.limit ?? 100,
        p_offset: query.offset ?? 0,
      },
    );

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getAccessLogs(
    tenantId: string,
    userId?: string,
    fromDate?: string,
    toDate?: string,
  ) {
    const supabase = this.supabaseService.getClient();

    let query = supabase
      .from('data_access_logs')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (userId) {
      query = query.eq('user_id', userId);
    }
    if (fromDate) {
      query = query.gte('created_at', fromDate);
    }
    if (toDate) {
      query = query.lte('created_at', toDate);
    }

    const { data, error } = await query;

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getLoginHistory(
    tenantId: string,
    userId?: string,
    email?: string,
    fromDate?: string,
    toDate?: string,
  ) {
    const supabase = this.supabaseService.getClient();

    let query = supabase
      .from('login_history')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (userId) {
      query = query.eq('user_id', userId);
    }
    if (email) {
      query = query.eq('email', email);
    }
    if (fromDate) {
      query = query.gte('created_at', fromDate);
    }
    if (toDate) {
      query = query.lte('created_at', toDate);
    }

    const { data, error } = await query;

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async generateComplianceReport(
    tenantId: string,
    fromDate: string,
    toDate: string,
  ) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc(
      'generate_compliance_report',
      {
        p_tenant_id: tenantId,
        p_from_date: fromDate,
        p_to_date: toDate,
      },
    );

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async configureRetentionPolicy(
    tenantId: string,
    logType: string,
    retentionDays: number,
  ) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase
      .from('audit_retention_policies')
      .upsert({
        tenant_id: tenantId,
        log_type: logType,
        retention_days: retentionDays,
      }, { onConflict: 'tenant_id, log_type' })
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async applyRetentionPolicy(tenantId: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc(
      'apply_retention_policy',
      {
        p_tenant_id: tenantId,
      },
    );

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }
}
