import { Global, Module } from '@nestjs/common';

import { DatabaseController } from './database.controller';
import { SupabaseService } from './supabase.service';

@Global()
@Module({
  controllers: [DatabaseController],
  providers: [SupabaseService],
  exports: [SupabaseService],
})
export class DatabaseModule {}