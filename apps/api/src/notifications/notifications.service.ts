import { Injectable, BadRequestException, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { CreateTemplateDto } from './dto/create-template.dto';
import { QueueNotificationDto } from './dto/queue-notification.dto';

@Injectable()
export class NotificationsService {
  constructor(private readonly supabase: SupabaseService) {}

  async createTemplate(tenantId: string, dto: CreateTemplateDto) {
    const { data, error } = await this.supabase.getClient()
      .from('notification_templates')
      .insert({
        tenant_id: tenantId,
        code: dto.code,
        name: dto.name,
        channel: dto.channel,
        subject: dto.subject,
        body_template: dto.bodyTemplate,
        variables: dto.variables || [],
        event_trigger: dto.eventTrigger,
        is_active: dto.isActive ?? true,
      })
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getTemplates(tenantId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('notification_templates')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async updateTemplate(tenantId: string, id: string, dto: Partial<CreateTemplateDto>) {
    const { data, error } = await this.supabase.getClient()
      .from('notification_templates')
      .update({
        name: dto.name,
        subject: dto.subject,
        body_template: dto.bodyTemplate,
        variables: dto.variables,
        event_trigger: dto.eventTrigger,
        is_active: dto.isActive,
      })
      .eq('id', id)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    if (!data) {
      throw new NotFoundException('Template not found');
    }

    return data;
  }

  async queueNotification(tenantId: string, dto: QueueNotificationDto) {
    const { data, error } = await this.supabase.getClient()
      .rpc('queue_notification', {
        p_tenant_id: tenantId,
        p_template_code: dto.templateCode,
        p_channel: dto.channel,
        p_recipient_type: dto.recipientType,
        p_recipient_id: dto.recipientId,
        p_recipient_address: dto.recipientAddress,
        p_variables: dto.variables || {},
        p_reference_type: dto.referenceType || null,
        p_reference_id: dto.referenceId || null,
        p_priority: dto.priority || 'NORMAL'
      });

    if (error) {
      throw new BadRequestException(error.message);
    }

    if (!data.success) {
      throw new BadRequestException(data.message || 'Failed to queue notification');
    }

    return data;
  }

  async processQueue(tenantId: string, batchSize: number = 50) {
    const { data, error } = await this.supabase.getClient()
      .rpc('process_notification_queue', {
        p_tenant_id: tenantId,
        p_batch_size: batchSize
      });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getHistory(tenantId: string, recipientId: string) {
    const { data, error } = await this.supabase.getClient()
      .rpc('get_notification_history', {
        p_tenant_id: tenantId,
        p_recipient_id: recipientId
      });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async updatePreferences(tenantId: string, customerId: string, channel: string, isEnabled: boolean) {
    const { data, error } = await this.supabase.getClient()
      .from('notification_preferences')
      .upsert(
        {
          tenant_id: tenantId,
          customer_id: customerId,
          channel: channel,
          is_enabled: isEnabled,
        },
        { onConflict: 'tenant_id,customer_id,channel' }
      )
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getPreferences(tenantId: string, customerId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('notification_preferences')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('customer_id', customerId);

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }
}
