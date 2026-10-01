import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DatabaseModule } from '../database/database.module';
import { SaasController } from './saas.controller';
import { SaasService } from './saas.service';
import { SuperAdminGuard } from './guards/super-admin.guard';

@Module({
  imports: [AuthModule, DatabaseModule],
  controllers: [SaasController],
  providers: [SaasService, SuperAdminGuard],
  exports: [SaasService],
})
export class SaasModule {}
