import { Controller, Get } from '@nestjs/common';

import { SupabaseService } from './supabase.service';

@Controller('health')
export class DatabaseController {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  @Get()
  async health() {
    const { data, error } = await this.supabaseService
      .getClient()
      .from('tenants')
      .select('id')
      .limit(1);

    if (error) {
      console.error('Supabase health check failed:', error);

      return {
        status: 'error',
        database: 'disconnected',
        error: error.message,
        code: error.code,
        details: error.details,
        hint: error.hint,
      };
    }

    return {
      status: 'ok',
      database: 'connected',
      rows: data?.length ?? 0,
    };
  }
}